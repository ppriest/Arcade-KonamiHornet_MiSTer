// SPDX-License-Identifier: GPL-3.0-or-later
//
// ADSP-21062 SHARC, v2: v1's MAME transcription (rtl/cpu/sharc) as an in-order pipeline,
// docs/SHARC_V2.md. Same ports as sharc_core, plus `serial`.
//
//   F  PM address: the next instruction of MAME's fetch queue (daddr, faddr, nfaddr), with the
//      loop end's jump back predicted
//   D  PM data; decode; R operands read with forwarding from X and W; interlock on a result
//      that is not ready (float, fixed multiply and loads are ready in W, the rest in X)
//   X  execute_run's per-instruction work: interrupts and the pc shift (fetch_step), the loop
//      end, the handler (sharc2_ops.svh), the fixed ALU and shifter, DM accesses, post-modify,
//      the system-register and IOP-write counters. Accesses that are not internal DM loads and
//      stores of R take more clocks (external bus, IOP, program memory, other registers), as
//      v1's P_MEM/P_MEMWAIT
//   W  float units, fixed multiply, load data: written to R, flags to ASTAT/STKY
//
// X is where the architectural state changes, in program order; the instruction in X checks
// that it is the one MAME's queue names and is squashed otherwise, so the fetch side only
// predicts. ASTAT/STKY: X's changes land at the X edge, W's (older instruction) first at the
// same edge; an instruction that reads them waits while W's are pending.
//
// DMA (channels 6 and 7): v1's one word per channel after each instruction, run by an engine
// beside the pipeline. With DMA_LOCK (MAME's order, the benches) the next instruction's end waits
// for it; without (the board), an instruction ends while the engine works and the next quantum
// starts after the next instruction that finds it free (docs/HACKS.md). `serial` (benches): one
// instruction in the pipeline at a time and DMA between them, so that the state at dbg_exec is
// MAME's before the instruction, as v1's.

module sharc2_core #(
    parameter int PM_WORDS = 20480,
    parameter int DM_WORDS = 32768,     // block 1 as built: addresses above it alias (the board's 16K,
                                        // gradius4's use: docs/HACKS.md)
    parameter bit BENCH = 0,            // X reads its R operands again in serial mode (bench pokes)
    parameter bit DMA_LOCK = 1,         // an instruction's end waits for the last DMA quantum
    parameter bit DMA_PACK = 1,         // DMA packing (PMODE); 0: none (DTYPE's 48-bit words stay)
    parameter bit SUBSET = 0,           // gradius4's subset: no type 1 (dual access) and the compute
                                        // operations of sharc2_pkg comp_unsup left out; `unsup` flags one
    parameter bit ONE_FADD = 0          // one float adder: a dual FADD/FSUB takes a clock more in X
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        boot,
    input  logic        serial,

    output logic        ext_req,
    output logic        ext_we,
    output logic [31:0] ext_addr,
    output logic [31:0] ext_wdata,
    input  logic        ext_ack,
    input  logic [31:0] ext_rdata,
    input  logic        ext_post,       // an external write asked for at this edge is taken next clock

    input  logic [2:0]  irq_in,
    input  logic [2:0]  irq_assert,
    input  logic        irq_check_en,
    input  logic [31:0] dbg_irq_set,
    input  logic        dbg_iop_ovr,    // benches: IOP reads return dbg_iop_val (MAME's DMA status)
    input  logic [31:0] dbg_iop_val,

    output logic        dbg_exec,
    output logic [23:0] dbg_pc,
    output logic [47:0] dbg_op,
    input  logic [5:0]  dbg_sel,
    output logic [31:0] dbg_val,
    output logic        dbg_idle,
    output logic        unsup,          // SUBSET: an instruction outside it executed (sticky until reset)
    input  logic        dbg_pm_we,
    input  logic [14:0] dbg_pm_addr,
    input  logic [47:0] dbg_pm_wdata,
    input  logic        dbg_dm_we,
    input  logic [14:0] dbg_dm_addr,
    input  logic [31:0] dbg_dm_wdata,
    input  logic        dbg_we,
    input  logic [7:0]  dbg_wsel,
    input  logic [5:0]  dbg_widx,
    input  logic [63:0] dbg_wdata
);

import sharc_fp_pkg::*;
import sharc2_pkg::*;

localparam logic [31:0] FLGS = 32'h0078_0000;
localparam logic [31:0] PCFL = 32'h0020_0000, PCEM = 32'h0040_0000, SSOV = 32'h0080_0000,
                        SSEM = 32'h0100_0000, LSOV = 32'h0200_0000, LSEM = 32'h0400_0000;
localparam logic [31:0] MODE1_ALUSAT = 32'h2000, MODE1_IRPTEN = 32'h1000, MODE1_TRUNCATE = 32'h8000;

// ------------------------------------------------------------------------------------------
// State
// ------------------------------------------------------------------------------------------

typedef struct packed {
    logic [31:0] addr;
    logic [4:0]  code;
    logic [1:0]  loop_type;
} laddr_t;

// the sequencer's registers (MAME's sharc_internal_state without R, the DAGs, the PC, loop and
// status stack arrays and the DMA transfer state)
typedef struct packed {
    logic [31:0] pc, daddr, faddr, nfaddr, delay_slot1, delay_slot2;
    logic [31:0] pcstk, pcstkp;
    logic [31:0] curlcntr, lcntr, lstkp;
    laddr_t      laddr;
    logic [31:0] status_stkp;
    logic [31:0] astat, astat_old, astat_old_old, astat_old_old_old;
    logic [31:0] mode1, mode2, stky, irptl, imask, imaskp, ustat1, ustat2;
    logic [47:0] px;
    logic [3:0]  flag;
    logic [31:0] syscon, sysstat;
    logic        idle;
    logic [31:0] irq_pending, active_irq_num;
    logic        interrupt_active;
    logic [31:0] lat_cycles, lat_reg, lat_data, lat_prev;
    logic [1:0][31:0] dma_control, dma_int_index, dma_int_modifier, dma_int_count,
                      dma_chain_ptr, dma_gen, dma_ext_index, dma_ext_modifier, dma_ext_count;
    logic [31:0] iop_delay_reg, iop_delay_data, iop_delay_cycles;
} q_t;

typedef enum logic [2:0] {
    A_DM_RD, A_DM_WR, A_PM_RD32, A_PM_WR32, A_PM_RD48, A_PM_WR48
} acc_kind_t;

typedef struct packed {
    logic        valid;
    acc_kind_t   kind;
    logic [31:0] addr;
    logic [47:0] wdata;
    logic [1:0]  dest_kind;      // 0 dreg, 1 ureg, 2 px, 3 none
    logic [7:0]  dest;
    logic        post_mod;
    logic        post_pm;
    logic [2:0]  post_i;
    logic [31:0] post_m;         // the modifier
    logic [31:0] post_s;         // I + the modifier, from D
} acc_t;

// one X clock's work: the new sequencer state and the requests applied at the edge
typedef struct packed {
    q_t          s;
    logic [63:0] apre, apost, spre, spost;     // {clear, set} before and after the compute point
    logic        cp;                           // the compute point is passed
    logic        compute, shimm;               // the ALU executes (compute field or immediate shift)
    logic [31:0] c_mode1, c_astat;             // MODE1 and ASTAT at the compute point
    logic        uwe;  logic [3:0] ur;  logic [31:0] ud;           // R by set_ureg
    logic        ureq; logic [7:0] uq_u; logic [31:0] uq_d;        // the handler's set_ureg
    logic [31:0] usrc;                                             // its source ureg's value
    logic [31:0] rI1, rM1, rI2, rM2;                               // DAG read ports (dag_ports)
    logic [1:0]  pmr; logic [1:0][2:0] pmi; logic [1:0][31:0] pmm, pms;  // post-modifies: modifier, sum
    // stack and jump requests (the micro-ops after the handler)
    logic        r_push_loop, r_pop_loop, r_push_status, r_pop_status, r_push_pc, r_pop_pc;
    logic        r_pcstk, r_jump, r_jpop, r_j, r_rti, r_do;
    logic [31:0] r_pcstk_v, r_target;
    laddr_t      r_laddr;
    logic        dwe;  logic dg; logic [1:0] dk; logic [2:0] di; logic [31:0] dd;   // DAG by set_ureg
    logic [1:0]  pwe;  logic [1:0][2:0] pi; logic [1:0][31:0] pd;  // post-modify, DAG1 / DAG2
    logic        psw;  logic [4:0] psi; logic [31:0] psd;          // PC stack array
    logic        lcw, law, ssw;                                    // loop stacks at LSTKP - 1, status
    logic [31:0] lcd, lad, ssm, ssa;                               // stack at STATUS_STKP (u_lc, u_la, u_ss*)
    logic [1:0]  lwe;  logic [1:0][3:0] lr; logic [1:0][31:0] ld;     // R loads (slow path, to W)
    acc_t [1:0]  a;
    logic [1:0]  n;
    logic        irq_taken;
    logic        dma_exec, dma_exec_ch;
    logic [5:0]  swap;                         // RF high, RF low, DAG2 low, DAG2 high, DAG1 low, DAG1 high
    logic        iow; logic [7:0] iow_a; logic [31:0] iow_d;   // an IOP register write (iop_write at the commit)
} xc_t;

q_t          Q;
// R and the DAG registers with their alternates: each register's two copies, the bank bit (bk)
// picking the one in use; MODE1's register-set swaps toggle bk (swap_req's bit order)
logic [5:0]  bk;                   // RF high, RF low, DAG2 low, DAG2 high, DAG1 low, DAG1 high
logic [31:0] rfp [32];
logic [31:0] rf [16];              // the registers in use

function automatic logic rbk(input logic [3:0] r);
    rbk = r[3] ? bk[5] : bk[4];
endfunction
function automatic logic dbk(input logic g, input logic [2:0] i);
    dbk = bk[{g, ~i[2]}];
endfunction
always_comb
    for (int k = 0; k < 16; k++) rf[k] = rfp[{rbk(4'(k)), 4'(k)}];

// The DAG registers in MLAB (sharc2_lutram): per DAG and kind (array g * 4 + k: I, M, L, B) the 16
// words {bank, register}, one write port, and a copy for each reader: D (its instruction's
// operands), X (get_ureg; XS_STEP's post-modify) and, in benches, dbg_val (I and M)
logic        dg_we [8];
logic [3:0]  dg_wa [8];
logic [31:0] dg_wd [8];
logic [31:0] dgd_q [8], dgx_q [8], dgb_q [8];
logic [2:0]  dgd_i [8];            // D's register in each array
logic [2:0]  dgx_i [2];            // X's register in each DAG
genvar ga;
generate for (ga = 0; ga < 8; ga++) begin : g_dag
    sharc2_lutram #(.AW(4), .DW(32)) u_d (.clk, .we(dg_we[ga]), .wa(dg_wa[ga]), .wd(dg_wd[ga]),
        .ra({dbk(1'(ga / 4), dgd_i[ga]), dgd_i[ga]}), .rd(dgd_q[ga]));
    sharc2_lutram #(.AW(4), .DW(32)) u_x (.clk, .we(dg_we[ga]), .wa(dg_wa[ga]), .wd(dg_wd[ga]),
        .ra({dbk(1'(ga / 4), dgx_i[ga / 4]), dgx_i[ga / 4]}), .rd(dgx_q[ga]));
    if (BENCH && (ga % 4) < 2) begin : g_dbg
        sharc2_lutram #(.AW(4), .DW(32)) u_b (.clk, .we(dg_we[ga]), .wa(dg_wa[ga]), .wd(dg_wd[ga]),
            .ra({dbk(1'(ga / 4), dbg_sel[2:0]), dbg_sel[2:0]}), .rd(dgb_q[ga]));
    end else begin : g_nodbg
        assign dgb_q[ga] = 32'h0;
    end
end endgenerate
logic [31:0] pcs_rd;               // the PC stack array's read port (sharc2_lutram, below)
logic [31:0] lc_rd, la_rd, ssm_rd, ssa_rd;     // the loop and status stack arrays' (below)
logic [63:0] mrf, mrb;

// DMA transfer state (sharcdma.hxx dma_op), the engine's
logic [1:0][31:0] op_src, op_dst, op_src_mod, op_dst_mod, op_src_count, op_dst_count, op_pmode,
                  op_chain_ptr, op_chain_dir;
logic [1:0]       op_active, op_chained, op_tcb;
logic [31:0]      dma_status;

// ------------------------------------------------------------------------------------------
// Memories
// ------------------------------------------------------------------------------------------

function automatic logic is_pm(input logic [31:0] a);
    is_pm = a >= 32'h20000 && a <= 32'h24FFF;
endfunction
function automatic logic is_dm1(input logic [31:0] a);
    is_dm1 = a >= 32'h28000 && a <= 32'h3FFFF;
endfunction

// program memory: one read port (fetch, X's PM reads), one write port
(* max_depth = 2048 *) logic [47:0] pm [PM_WORDS];             // x5 slices: 100 M10K, not 120
logic [14:0] pm_ra_c;
logic        pm_en;                                       // the read happens (else pm_q holds)
logic [47:0] pm_q;
logic        pm_we;
logic [14:0] pm_wa;
logic [47:0] pm_wd;
always_ff @(posedge clk) begin
    if (pm_en) pm_q <= pm[pm_ra_c];
    if (dbg_pm_we) pm[dbg_pm_addr] <= dbg_pm_wdata;
    else if (pm_we) pm[pm_wa] <= pm_wd;
end

// data memory (block 1): port A for X, port B for X's second access, the DMA engine and boot
logic [14:0] dma_a_c, dma_a_q, dmb_a_c, dmb_a_q;
logic        dma_we_c, dmb_we_c;
logic [31:0] dma_wd_c, dmb_wd_c, dm_qa, dm_qb;
localparam int DMAW = $clog2(DM_WORDS);
hornet_dpram #(.AW(DMAW), .DW(32), .WORD(1), .MAXD(2048)) u_dm (   // x5 slices: 112 M10K at 32K, not 128
    .clk,
    .a_addr(dma_a_c[DMAW-1:0]), .a_be({4{dma_we_c}}), .a_wdata(dma_wd_c), .a_rdata(dm_qa),
    .b_addr(dmb_a_c[DMAW-1:0]), .b_be({4{dmb_we_c}}), .b_wdata(dmb_wd_c), .b_rdata(dm_qb)
);
always_ff @(posedge clk) begin dma_a_q <= dma_a_c; dmb_a_q <= dmb_a_c; end

// simulation: an early load is the access X makes
// synthesis translate_off
always_ff @(posedge clk)
    if (ce && w_lwe[0] && w_lsrc[0] == 2'd3 && w_ebuf != dm_qa)
        $error("SHARC: early load into R%0d took %08X, the late read %08X", w_lr[0], w_ebuf, dm_qa);
always_ff @(posedge clk)
    if (ce && x_valid && x_el && x_hcommit &&
        !(x_fast && c.n == 2'd1 && c.a[0].kind == A_DM_RD && c.a[0].addr == x_ea && c.a[0].dest[3:0] == x_el_r &&
          (c.a[0].dest_kind == 2'd0 || c.a[0].dest[7:4] == 4'h0)))
        $error("SHARC: early load at %05X (R%0d) is not X's access (%05X, kind %0d, n %0d, fast %0d)",
               x_ea, x_el_r, c.a[0].addr, c.a[0].kind, c.n, x_fast);
// synthesis translate_on

// simulation: an access past the block as built
// synthesis translate_off
always_ff @(posedge clk)
    if (DM_WORDS < 32768 && ce && run && !booting && !dbg_dm_we &&
        ((dma_a_c != dma_a_q || dma_we_c) && 32'(dma_a_c) >= DM_WORDS ||
         (dmb_a_c != dmb_a_q || dmb_we_c) && 32'(dmb_a_c) >= DM_WORDS))
        $error("SHARC: data memory access at %05X, past the %0d words built", 32'h28000 + 32'(dma_a_c >= DM_WORDS ? dma_a_c : dmb_a_c), DM_WORDS);
// synthesis translate_on

// ------------------------------------------------------------------------------------------
// Pipeline registers
// ------------------------------------------------------------------------------------------

typedef enum logic [2:0] { XS_EXEC, XS_ACC, XS_WAIT, XS_POST, XS_STEP } xph_t;

typedef struct packed {
    logic        comp_on;
    logic        shimm;
    logic [3:0]  i_ax, i_ay, i_mx, i_my, i_e, i_s1, i_s2;
    logic [15:0] rd;
    logic [15:0] ld;
    logic        needs_astat;
    logic        one;            // completes in its first clock when its accesses are fast
    logic        rdag;           // D reads DAG registers for it
    logic        wdag;           // may write a DAG register other than by an unconditional post-modify
    logic [1:0]  pmv;            // post-modifies DAG g unconditionally ...
    logic [1:0][2:0] pmi;        // ... register I[pmi]
    logic        uw;             // its handler writes R[uw_r] as a universal register (ureg = ureg, ureg = data)
    logic [3:0]  uw_r;
} dec_t;

// D
logic        d_valid;
logic [31:0] d_pc;
// X
logic        x_valid;
logic [31:0] x_pc;
logic [47:0] x_op;
dec_t        x_dec;
xph_t        xph;
logic [31:0] x_ax, x_ay, x_mx, x_my, x_e, x_s1, x_s2;
// X's results of the clock its instruction left D, and which of them each operand takes instead of
// the value above ({ureg, Rx1, Rx0}, ax ay mx my e s1 s2): X's write enables decide late in the
// clock, so they go into these bits rather than through the operand muxes (fwd_d, fwd_sel)
logic [31:0] x_fw0, x_fw1, x_fwu;
logic [2:0]  x_fs [7];
logic [15:0] x_late;               // R written in W by the instruction in X
logic [15:0] x_late_ld;            // ... by its loads only (benches: dbg_hz)
logic        x_dmw, x_pb;          // X's instruction may write data memory; may use DM port B
logic        x_el;                 // X's load was read early (D's ld_go)
logic [3:0]  x_el_r;               // ... into R[x_el_r]
logic        x_ef;                 // ... in the clock before: its data is on dm_qb now
logic [31:0] x_eld;                // ... its data, kept from that clock
logic [31:0] w_ebuf;               // W's copy of an early load's data (w_lsrc 3)
logic [31:0] x_ea;                 // ... its address (simulation's check)
logic [31:0] el_d;                 // the early load's data
logic        el_fwd;               // ... goes to R[x_el_r] at this edge
acc_t [1:0]  x_acc;
logic [1:0]  x_n;
logic        x_cur;
logic [1:0][47:0] x_rdata;
logic [15:0] x_kill;               // R the instruction's set_ureg wrote after its compute
// W loads
logic [1:0]  w_lwe;
logic [1:0][3:0] w_lr;
logic [1:0][1:0] w_lsrc;           // 0 port A, 1 port B, 2 buffered
logic [1:0][31:0] w_lbuf;
logic [15:0] w_kill;
logic [5:0]  swap_req;
logic        booting;
logic        run;                  // a bench has loaded the state, or boot finished
logic [2:0]  irq_prev;
// the ALU's X inputs as the handler set them, held from its commit to the end of X
logic        x_c_compute, x_c_shimm;
logic        irq_entry;            // X's next instruction is the vector just taken
logic [31:0] x_c_mode1, x_c_astat;

// DMA engine
logic        e_busy, e_wait, e_start;
logic        e_tcb_next;               // a TCB word's read issued in the clock the last arrives
logic        e_rd_next;                // a transfer's next word's read issued with the last's ack
logic        e_post_now, e_post_rd;    // a Voodoo write posted (done when asked for), the next read
logic        eb_post;                  // eb_req holds a posted write, taken this clock
logic [1:0]  e_ch;
logic [3:0]  e_step;
logic [2:0]  e_k;
logic [47:0] e_pack;
logic [31:0] e_data;
logic [7:0][31:0] tcb;
logic [31:0] e_irq_set;            // IRPTL (and irq_pending where unmasked) bits set at this edge
logic        e_pmw;
logic [14:0] e_pmw_a;
logic [47:0] e_pmw_d;
logic        e_do;                 // the engine issues its access this clock
logic        e_portb_do, e_portb_we;
logic [14:0] e_portb_a;
logic [31:0] e_portb_wd;
logic [1:0]  e_sel;
logic [31:0] e_ad;
logic [3:0]  e_stp;

// EPROM boot
logic [15:0] boot_n;
logic        boot_clear;
logic [47:0] boot_w;
logic [2:0]  boot_k;
logic [7:0]  boot_pw;
logic        boot_pm_we, boot_dm_we, boot_done;
logic [14:0] boot_pm_wa, boot_dm_wa;
logic [47:0] boot_pm_wd;

// external bus: X, the engine, boot
logic        xb_req, xb_we;
logic [31:0] xb_addr, xb_wdata;
logic        eb_req, eb_we;
logic [31:0] eb_addr, eb_wdata;
logic        bb_req;
logic [31:0] bb_addr;

// ------------------------------------------------------------------------------------------
// D: decode and operands
// ------------------------------------------------------------------------------------------

function automatic dec_t d_decode(input logic [47:0] op);
    dec_t o;
    logic [22:0] comp;
    logic [8:0]  top;
    logic        has_cond;
    logic [4:0]  cond;
    logic [7:0]  u;
    cinfo_t      ci;
    o = '0;
    comp = op[22:0];
    top = op[47:39];
    o.i_ax = slot_ax(comp); o.i_ay = slot_ay(comp);
    o.i_mx = slot_mx(comp); o.i_my = slot_my(comp);
    o.i_e = comp[11:8];
    has_cond = 1'b0;
    cond = op[37:33];
    casez (top)
    9'b001??????: begin
        o.comp_on = 1'b1;
        o.i_s1 = op[36:33]; o.i_s2 = op[26:23];
        if (op[44]) o.rd |= bit16(op[36:33]); else o.ld |= bit16(op[36:33]);
        if (op[37]) o.rd |= bit16(op[26:23]); else o.ld |= bit16(op[26:23]);
    end
    9'b00000001?: begin o.comp_on = 1'b1; has_cond = 1'b1; end
    9'b0100?????, 9'b0101?????: begin
        o.comp_on = 1'b1; has_cond = 1'b1;
        u = op[30:23];
        if (u[7:4] == 4'h0) begin
            o.i_s1 = u[3:0];
            if (op[31]) o.rd |= bit16(u[3:0]); else o.ld |= bit16(u[3:0]);
        end
        if (op[31] && (u == 8'h7c || u == 8'h7e)) o.needs_astat = 1'b1;
    end
    9'b0110?????: begin
        o.comp_on = 1'b1; has_cond = 1'b1;
        o.i_s1 = op[26:23];
        if (op[39]) o.rd |= bit16(op[26:23]); else o.ld |= bit16(op[26:23]);
    end
    9'b0111?????: begin
        o.comp_on = 1'b1; has_cond = 1'b1; cond = op[35:31];
        u = op[43:36];
        if (u[7:4] == 4'h0) begin o.i_s1 = u[3:0]; o.rd |= bit16(u[3:0]); end
        if (u == 8'h7c || u == 8'h7e) o.needs_astat = 1'b1;
    end
    9'b1000?????: begin
        o.shimm = 1'b1; has_cond = 1'b1;
        o.i_ax = op[3:0]; o.i_e = op[7:4];
        o.rd |= bit16(op[3:0]) | bit16(op[7:4]);
        o.i_s1 = op[26:23];
        if (op[31]) o.rd |= bit16(op[26:23]); else o.ld |= bit16(op[26:23]);
    end
    9'b00000010?: begin
        o.shimm = 1'b1; has_cond = 1'b1;
        o.i_ax = op[3:0]; o.i_e = op[7:4];
        o.rd |= bit16(op[3:0]) | bit16(op[7:4]);
    end
    9'b00000100?: begin o.comp_on = 1'b1; has_cond = 1'b1; end
    9'b0000011??: has_cond = 1'b1;
    9'b0000100??: begin o.comp_on = 1'b1; has_cond = 1'b1; end
    9'b11???????: begin
        o.comp_on = 1'b1; has_cond = 1'b1;
        o.i_s1 = op[26:23];
        if (op[44]) o.rd |= bit16(op[26:23]); else o.ld |= bit16(op[26:23]);
    end
    9'b0000101??: begin o.comp_on = 1'b1; has_cond = 1'b1; end
    9'b00001100?, 9'b00001101?, 9'b00001110?:
        if (op[42:40] == 3'b101) begin
            u = op[39:32];
            if (u[7:4] == 4'h0) begin o.i_s1 = u[3:0]; o.rd |= bit16(u[3:0]); end
            if (u == 8'h7c || u == 8'h7e) o.needs_astat = 1'b1;
        end
    9'b000100???: begin
        u = op[39:32];
        if (u[7:4] == 4'h0) begin
            o.i_s1 = u[3:0];
            if (op[40]) o.rd |= bit16(u[3:0]); else o.ld |= bit16(u[3:0]);
        end
        if (op[40] && (u == 8'h7c || u == 8'h7e)) o.needs_astat = 1'b1;
    end
    9'b101??????: begin
        u = op[39:32];
        if (u[7:4] == 4'h0) begin
            o.i_s1 = u[3:0];
            if (op[40]) o.rd |= bit16(u[3:0]); else o.ld |= bit16(u[3:0]);
        end
        if (op[40] && (u == 8'h7c || u == 8'h7e)) o.needs_astat = 1'b1;
    end
    9'b00010100?: if (op[35:32] == 4'hc || op[35:32] == 4'he) o.needs_astat = 1'b1;
    9'b00010111?: if (op[37]) o.needs_astat = 1'b1;
    default: ;
    endcase
    if (o.comp_on) begin
        ci = comp_info(comp, SUBSET);
        o.rd |= ci.rd;
        if (ci.needs_astat) o.needs_astat = 1'b1;
    end
    if (has_cond && cond != 5'h1f) o.needs_astat = 1'b1;
    // the X sequencer's classes (sharc2_core X): micro-ops that may take clocks of their own
    casez (top)
    9'b0111?????: begin o.uw = op[30:27] == 4'h0; o.uw_r = op[26:23]; end
    9'b00001111?: begin o.uw = op[39:36] == 4'h0; o.uw_r = op[35:32]; end
    default: ;
    endcase
    o.one = 1'b1;
    casez (top)
    9'b00001100?, 9'b00001101?, 9'b00001110?, 9'b00010111?: o.one = 1'b0;      // DO, push/pop
    9'b00001010?, 9'b00001011?: o.one = !op[40];                                  // RTI
    9'b0000011??: o.one = op[39] || (!op[38] && !op[24]);                         // LA, CI
    9'b0000100??: o.one = op[39] || (!op[38] && !op[24]);                         // LA, CI
    9'b0111?????: o.one = ureg_simple(op[30:23]);
    9'b00001111?: o.one = ureg_simple(op[39:32]);
    9'b00010100?: o.one = ureg_simple({4'h7, op[35:32]});
    default: ;
    endcase
    casez (top)
    9'b001??????, 9'b0100?????, 9'b0101?????, 9'b0110?????, 9'b1000?????, 9'b00000100?, 9'b0000100??,
    9'b11???????, 9'b101??????, 9'b1001?????, 9'b000101100: o.rdag = 1'b1;
    default: o.rdag = 1'b0;
    endcase
    // DAG writes: a universal-register destination in a DAG (0x1x-0x4x), or a conditional post-modify
    casez (top)
    9'b0100?????, 9'b0101?????: begin
        o.wdag = (!op[31] && op[30:27] >= 4'h1 && op[30:27] <= 4'h4) || (op[44] && cond != 5'h1f);
        if (op[44] && cond == 5'h1f) begin o.pmv[op[32]] = 1'b1; o.pmi[op[32]] = op[43:41]; end
    end
    9'b0110?????: begin
        o.wdag = op[38] && cond != 5'h1f;
        if (op[38] && cond == 5'h1f) begin o.pmv[op[40]] = 1'b1; o.pmi[op[40]] = op[43:41]; end
    end
    9'b0111?????: o.wdag = op[30:27] >= 4'h1 && op[30:27] <= 4'h4;
    9'b00001111?: o.wdag = op[39:36] >= 4'h1 && op[39:36] <= 4'h4;
    9'b000100???, 9'b101??????: o.wdag = !op[40] && op[39:36] >= 4'h1 && op[39:36] <= 4'h4;
    9'b001??????: begin o.pmv = 2'b11; o.pmi[0] = op[43:41]; o.pmi[1] = op[32:30]; end
    9'b1000?????: begin
        o.wdag = cond != 5'h1f;
        if (cond == 5'h1f) begin o.pmv[op[32]] = 1'b1; o.pmi[op[32]] = op[43:41]; end
    end
    9'b00000100?: begin
        o.wdag = cond != 5'h1f;
        if (cond == 5'h1f) begin o.pmv[op[38]] = 1'b1; o.pmi[op[38]] = op[32:30]; end
    end
    9'b11???????: o.wdag = 1'b1;                    // the access is the not-taken branch's
    9'b1001?????: begin o.pmv[op[37]] = 1'b1; o.pmi[op[37]] = op[43:41]; end
    9'b000101100: begin o.pmv[op[38]] = 1'b1; o.pmi[op[38]] = op[34:32]; end
    default: o.wdag = 1'b0;
    endcase
    return o;
endfunction

// d_decode's R reads (rd) against a mask, as an OR over the instruction's register fields: each
// field indexes the mask straight from the opcode bits, beside the decode, rather than after it.
// Equal to (d_decode(op).rd & m) != 0 (checked in simulation below).
function automatic logic late_hit(input logic [47:0] op, input logic [15:0] m);
    logic [22:0] c;
    logic [8:0]  top;
    logic        h, comp_on;
    logic [5:0]  mop;
    c = op[22:0];
    top = op[47:39];
    h = 1'b0;
    comp_on = 1'b0;
    casez (top)
    9'b001??????: begin
        comp_on = 1'b1;
        h = (op[44] && m[op[36:33]]) || (op[37] && m[op[26:23]]);
    end
    9'b00000001?, 9'b00000100?, 9'b0000100??, 9'b0000101??: comp_on = 1'b1;
    9'b0100?????, 9'b0101?????: begin
        comp_on = 1'b1;
        h = op[30:27] == 4'h0 && op[31] && m[op[26:23]];
    end
    9'b0110?????: begin comp_on = 1'b1; h = op[39] && m[op[26:23]]; end
    9'b0111?????: begin comp_on = 1'b1; h = op[43:40] == 4'h0 && m[op[39:36]]; end
    9'b1000?????: h = m[op[3:0]] || m[op[7:4]] || (op[31] && m[op[26:23]]);
    9'b00000010?: h = m[op[3:0]] || m[op[7:4]];
    9'b11???????: begin comp_on = 1'b1; h = op[44] && m[op[26:23]]; end
    9'b00001100?, 9'b00001101?, 9'b00001110?:
        h = op[42:40] == 3'b101 && op[39:36] == 4'h0 && m[op[35:32]];
    9'b000100???, 9'b101??????: h = op[39:36] == 4'h0 && op[40] && m[op[35:32]];
    default: ;
    endcase
    // comp_info's reads
    mop = c[21:16];
    if (comp_on && c != 0) begin
        if (!c[22])
            h = h || m[c[7:4]] || m[c[3:0]] || (c[21:20] == 2'd2 && m[c[11:8]]);
        else if (mop == 6'h01)
            h = h || m[c[11:8]];
        else if (mop == 6'h04 || mop == 6'h05 || mop[5:3] == 3'b011 || mop[5:4] == 2'b11)
            h = h || m[{2'b00, c[7:6]}] || m[{2'b01, c[5:4]}] || m[{2'b10, c[3:2]}] || m[{2'b11, c[1:0]}];
    end
    return h;
endfunction

dec_t   d_dec;
cinfo_t d_ci;

// the forms that may write data memory (sharc2_ops.svh's A_DM_WR), and the one that uses DM port B
function automatic logic dm_write_form(input logic [47:0] op);
    casez (op[47:39])
    9'b001??????:               dm_write_form = op[44];
    9'b0100?????, 9'b0101?????: dm_write_form = op[31] && !op[32];
    9'b0110?????:               dm_write_form = op[39] && !op[40];
    9'b1000?????:               dm_write_form = op[31] && !op[32];
    9'b110??????, 9'b111??????: dm_write_form = op[44];
    9'b000100???:               dm_write_form = op[41:40] == 2'b01;
    9'b101??????:               dm_write_form = op[40] && !op[44];
    9'b1001?????:               dm_write_form = !op[37];
    default:                    dm_write_form = 1'b0;
    endcase
endfunction

// D: the DAG registers D's instruction reads, as two ports (DAG1, DAG2: I and M; forms with a DAG
// select bit give both the same indices), and the sums the handler and its post-modify use (I + M,
// I + the immediate), with X's DAG writes of this clock forwarded
logic [31:0] d_dI [2], d_dM [2], d_dL [2], d_dB [2], d_imm [2], d_pd [2];
logic [31:0] x_dI [2], x_dM [2], x_sM [2], x_sX [2], x_pd [2];   // x_pd: I post-modified
logic        d_aok, x_aok;         // the form's accesses, if it makes them, all run as fast ones
assign d_dec = d_decode(pm_q);
assign d_ci = d_dec.comp_on ? comp_info(pm_q[22:0], SUBSET) : '0;
// synthesis translate_off
always_ff @(posedge clk)
    if (ce && late_hit(pm_q, x_late) != ((d_dec.rd & x_late) != 0))
        $error("SHARC: late_hit disagrees with d_decode at %05X: %012X", d_pc, pm_q);
// synthesis translate_on

// acc_fast of the form's accesses at D's addresses
always_comb begin
    logic [47:0] op;
    logic [31:0] sm [2], sx [2];
    logic [7:0]  u;
    op = pm_q;
    for (int g = 0; g < 2; g++) begin sm[g] = d_dI[g] + d_dM[g]; sx[g] = d_dI[g] + d_imm[g]; end
    d_aok = 1'b1;
    casez (op[47:39])
    9'b001??????: d_aok = is_dm1(d_dI[1]) && is_dm1(d_dI[0]) && !(op[37] && op[44] && d_dI[0] == d_dI[1]);
    9'b0100?????, 9'b0101?????: begin
        u = op[30:23];
        d_aok = is_dm1(op[44] ? d_dI[op[32]] : sm[op[32]]) && (op[31] || u[7:4] == 4'h0) && !(op[32] && u == 8'hdb);
    end
    9'b0110?????: d_aok = is_dm1(op[38] ? d_dI[op[40]] : sx[op[40]]);
    9'b1000?????: d_aok = is_dm1(d_dI[op[32]]);
    9'b11???????: d_aok = is_dm1(d_dI[0]);
    9'b000100???: begin
        u = op[39:32];
        d_aok = is_dm1(op[31:0]) && (op[40] || u[7:4] == 4'h0) && !(op[41] && u == 8'hdb);
    end
    9'b101??????: begin
        u = op[39:32];
        d_aok = is_dm1(op[44] ? sx[1] : sx[0]) && (op[40] || u[7:4] == 4'h0) && !(op[44] && u == 8'hdb);
    end
    9'b1001?????: d_aok = is_dm1(d_dI[op[37]]);
    default: ;
    endcase
end

// W and X results, for forwarding (below)
logic [2:0]  ww_we;
logic [3:0]  ww_r0, ww_r1, ww_r2;
logic [31:0] ww_d0, ww_d1, ww_d2;
logic [1:0][31:0] w_ld;
logic [1:0]  xw_we, xw_wr;
logic [3:0]  xw_r0, xw_r1;
logic [31:0] xw_d0, xw_d1;
xc_t         c;                    // X's work this clock (below)
// the handler's universal-register write to R, from the decoded form and its condition (the
// handler's own request, c.uwe, is the same write but late): in the handler's clock
logic        x_uw;
logic [31:0] x_uw_d;

// a DAG register (kind 0 I, 1 M, 2 L, 3 B) with X's writes of this clock
function automatic logic [31:0] dag_fwd(input logic g, input logic [1:0] k, input logic [2:0] i);
    dag_fwd = dgd_q[{g, k}];          // read at i (dgd_i)
    // X's unconditional post-modify (other DAG writes hold D: d_hazard)
    if (k == 2'd0 && x_valid && x_dec.pmv[g] && x_dec.pmi[g] == i) dag_fwd = x_pd[g];
endfunction

always_comb begin
    logic [47:0] op;
    logic [2:0]  i1, m1, i2, m2;
    op = pm_q;
    i1 = op[43:41]; m1 = op[40:38]; i2 = op[43:41]; m2 = op[40:38];
    casez (op[47:39])
    9'b001??????, 9'b0000100??, 9'b11???????: begin i2 = op[32:30]; m2 = op[29:27]; end
    9'b00000100?: begin i1 = op[32:30]; m1 = op[29:27]; i2 = op[32:30]; m2 = op[29:27]; end
    9'b000101100: begin i1 = op[34:32]; i2 = op[34:32]; end
    default: ;
    endcase
    d_imm[0] = op[31:0]; d_imm[1] = op[31:0];
    casez (op[47:39])
    9'b0110?????: begin d_imm[0] = {{26{op[32]}}, op[32:27]}; d_imm[1] = {{26{op[32]}}, op[32:27]}; end
    9'b101??????: d_imm[1] = op[40] ? op[31:0] : {8'h0, op[23:0]};
    default: ;
    endcase
    dgd_i[0] = i1; dgd_i[1] = m1; dgd_i[2] = i1; dgd_i[3] = i1;
    dgd_i[4] = i2; dgd_i[5] = m2; dgd_i[6] = i2; dgd_i[7] = i2;
    d_dI[0] = dag_fwd(1'b0, 2'd0, i1); d_dM[0] = dag_fwd(1'b0, 2'd1, m1);
    d_dI[1] = dag_fwd(1'b1, 2'd0, i2); d_dM[1] = dag_fwd(1'b1, 2'd1, m2);
    d_dL[0] = dag_fwd(1'b0, 2'd2, i1); d_dB[0] = dag_fwd(1'b0, 2'd3, i1);
    d_dL[1] = dag_fwd(1'b1, 2'd2, i2); d_dB[1] = dag_fwd(1'b1, 2'd3, i2);
    // the post-modify: I + M, or I + the immediate (0x0600 forms' modifier, MODIFY by immediate),
    // wrapped into the circular buffer
    for (int g = 0; g < 2; g++) begin
        logic [31:0] v;
        logic        imm;
        logic [31:0] bl;
        logic [32:0] t_hi, t_lo;
        imm = op[47:44] == 4'b0110 || op[47:39] == 9'b000101100;
        v = d_dI[g] + (imm ? d_imm[g] : d_dM[g]);
        bl = d_dB[g] + d_dL[g];                          // MAME's b + l, 32 bits
        // the compares as subtractions, for the carry chain: v > bl, v < b
        t_hi = {1'b0, bl} - {1'b0, v};
        t_lo = {1'b0, v} - {1'b0, d_dB[g]};
        d_pd[g] = v;
        if (d_dL[g] != 0) begin
            if (t_hi[32]) d_pd[g] = v - d_dL[g];
            else if (t_lo[32]) d_pd[g] = v + d_dL[g];
        end
    end
end

always_comb
    for (int k = 0; k < 2; k++)
        w_ld[k] = (w_lsrc[k] == 2'd0) ? dm_qa : (w_lsrc[k] == 2'd1) ? dm_qb : (w_lsrc[k] == 2'd3) ? w_ebuf : w_lbuf[k];


// XR: X's R writes (its compute's and its ureg write), applied to R the clock after X commits them,
// before W's of that clock (W holds the same instruction then, or an older one)
logic [2:0]  xr_we;                     // {ureg, Rx1, Rx0}
logic [3:0]  xr_r0, xr_r1, xr_ru;
logic [31:0] xr_d0, xr_d1, xr_du;
function automatic logic [31:0] xr_fwd(input logic [3:0] r);
    logic [31:0] v;
    v = rf[r];
    if (xr_we[0] && xr_r0 == r) v = xr_d0;
    if (xr_we[1] && xr_r1 == r) v = xr_d1;
    if (xr_we[2] && xr_ru == r) v = xr_du;
    return v;
endfunction

// R as D's instruction sees it at this edge, from R, XR and W; X's results of the clock are not in
// it: fwd_sel says which of them each operand takes, and X picks it (fwd_x)
function automatic logic [31:0] fwd_d(input logic [3:0] r);
    logic [31:0] v;
    v = xr_fwd(r);
    if (ww_we[0] && ww_r0 == r && !w_kill[r]) v = ww_d0;
    if (ww_we[1] && ww_r1 == r && !w_kill[r]) v = ww_d1;
    if (ww_we[2] && ww_r2 == r && !w_kill[r]) v = ww_d2;
    if (w_lwe[0] && w_lr[0] == r) v = w_ld[0];
    if (w_lwe[1] && w_lr[1] == r) v = w_ld[1];
    return v;
endfunction
// which of X's results of the clock R[r] takes at this edge
function automatic logic [2:0] fwd_sel(input logic [3:0] r);
    return {x_uw && x_dec.uw_r == r, x_hcommit && xw_we[1] && xw_r1 == r, x_hcommit && xw_we[0] && xw_r0 == r};
endfunction
function automatic logic [31:0] fwd_x(input logic [31:0] v, input logic [2:0] s);
    return s[2] ? x_fwu : s[1] ? x_fw1 : s[0] ? x_fw0 : v;
endfunction
// ... and X's early load, which beats them: its data is in hand at the edge, not X's results
function automatic logic [31:0] fwd_e(input logic [3:0] r);
    return (el_fwd && x_el_r == r) ? el_d : fwd_d(r);
endfunction
function automatic logic [2:0] fwd_sel_e(input logic [3:0] r);
    return (el_fwd && x_el_r == r) ? 3'b000 : fwd_sel(r);
endfunction

// ------------------------------------------------------------------------------------------
// ALU
// ------------------------------------------------------------------------------------------

logic        d_go, x_go, d_mc_wait, x_busy, x_alu_needs_astat;
logic [31:0] x_aclr, x_aset, x_sset, w_aclr, w_aset, w_sset;
logic        x_mrf_we, x_mrb_we, w_on;
logic [63:0] x_mr_d;
logic [31:0] ax_e, ay_e, mx_e, my_e, e_e, xs1, xs2;

// bench pokes change R between D and X in serial mode
assign ax_e = (BENCH && serial) ? rf[x_dec.i_ax] : fwd_x(x_ax, x_fs[0]);
assign ay_e = (BENCH && serial) ? rf[x_dec.i_ay] : fwd_x(x_ay, x_fs[1]);
assign mx_e = (BENCH && serial) ? rf[x_dec.i_mx] : fwd_x(x_mx, x_fs[2]);
assign my_e = (BENCH && serial) ? rf[x_dec.i_my] : fwd_x(x_my, x_fs[3]);
assign e_e  = (BENCH && serial) ? rf[x_dec.i_e]  : fwd_x(x_e, x_fs[4]);
assign xs1  = (BENCH && serial) ? rf[x_dec.i_s1] : fwd_x(x_s1, x_fs[5]);
assign xs2  = (BENCH && serial) ? rf[x_dec.i_s2] : fwd_x(x_s2, x_fs[6]);

logic        alu_exec, alu_shimm;
logic [31:0] alu_mode1, alu_astat;
assign alu_exec  = (x_hclk || xph == XS_EXEC) ? c.compute : x_c_compute;
assign alu_shimm = x_dec.shimm;          // the form (decode); the condition gates alu_exec
assign alu_mode1 = (x_hclk || xph == XS_EXEC) ? c.c_mode1 : x_c_mode1;
assign alu_astat = (x_hclk || xph == XS_EXEC) ? c.c_astat : x_c_astat;

sharc2_alu #(.SUBSET(SUBSET), .ONE_FADD(ONE_FADD)) u_alu (
    .clk, .ce,
    .d_go, .d_comp_on(d_dec.comp_on), .d_comp(pm_q[22:0]),
    .d_ax(fwd_e(d_dec.i_ax)), .d_ay(fwd_e(d_dec.i_ay)), .d_mc_wait,
    .x_go, .x_drop(x_squash), .x_exec(alu_exec), .x_comp_on(x_dec.comp_on && !alu_shimm), .x_comp(x_op[22:0]),
    .x_shimm(alu_shimm), .x_shimm_op(x_op[21:16]), .x_shimm_data({x_op[30:27], x_op[15:8]}),
    .x_shimm_rn(x_op[7:4]),
    .ax(ax_e), .ay(ay_e), .mx(mx_e), .my(my_e), .xe(e_e),
    .astat_in(alu_astat),
    .trunc((alu_mode1 & MODE1_TRUNCATE) != 0), .alusat((alu_mode1 & MODE1_ALUSAT) != 0),
    .mrf, .mrb,
    .x_busy, .x_needs_astat(x_alu_needs_astat),
    .xw_we, .xw_wr, .xw_r0, .xw_r1, .xw_d0, .xw_d1,
    .x_aclr, .x_aset, .x_sset,
    .x_mrf_we, .x_mrb_we, .x_mr_d,
    .w_on, .ww_we, .ww_r0, .ww_r1, .ww_r2, .ww_d0, .ww_d1, .ww_d2,
    .w_aclr, .w_aset, .w_sset
);

// ASTAT and STKY with W's update (the architectural values before X's instruction)
logic [31:0] astat_fwd, stky_fwd;
assign astat_fwd = (Q.astat & ~w_aclr) | w_aset;
assign stky_fwd  = Q.stky | w_sset;

`include "sharc2_ops.svh"

// ------------------------------------------------------------------------------------------
// DMA engine (v1 P_DMA, P_DMAWAIT)
// ------------------------------------------------------------------------------------------

function automatic logic [2:0] dma_reads(input logic [31:0] pmode);
    dma_reads = (pmode == 32'd1) ? 3'd2 : (pmode == 32'd4) ? 3'd6 : 3'd1;
endfunction

// the channel this clock: from e_ch on; without DMA_LOCK (the board) round, so that a word follows
// the last without a clock finding no channel
always_comb
    if (e_ch == 2'd0 && dma_status[6])      e_sel = 2'd0;
    else if (e_ch <= 2'd1 && dma_status[7]) e_sel = 2'd1;
    else if (!DMA_LOCK && !serial && e_ch == 2'd1 && dma_status[6]) e_sel = 2'd0;
    else                                    e_sel = 2'd2;

function automatic logic [3:0] e_eff_step(input logic ch, input logic [3:0] stp);
    e_eff_step = (op_tcb[ch] && stp < 4'd2) ? 4'd2 : stp;
endfunction
function automatic logic [31:0] e_addr(input logic ch, input logic [3:0] stp);
    if (stp == 4'd0)      e_addr = op_src[ch] + {29'h0, e_k};
    else if (stp == 4'd1) e_addr = op_dst[ch];
    else                  e_addr = 32'h20000 + (op_chain_ptr[ch] & 32'h1FFFF) - {28'h0, stp} + 32'd2;
endfunction

// ------------------------------------------------------------------------------------------
// X: this clock's work
// ------------------------------------------------------------------------------------------
//
// An instruction is MAME's micro-ops in order: the pc shift and the loop end (its first clock),
// a jump's clear-interrupt, the handler (compute, accesses), the stack operations, the jump, RTI,
// the universal-register write, the interrupt check, the slow accesses, the post-modifies and the
// counters. The handler shares its clock with the shift, the loop end (unless it reads what the
// loop end changes) and the leading micro-ops that write other state (op_fuse); the rest take a
// clock each (XS_STEP), the slow accesses theirs (XS_ACC, XS_WAIT, XS_POST).

localparam int OP_CLEARINT = 0, OP_HANDLER = 1, OP_PUSH_LOOP = 2, OP_POP_LOOP = 3, OP_DO = 4,
               OP_PUSH_ST = 5, OP_POP_ST = 6, OP_PUSH_PC = 7, OP_POP_PC = 8, OP_JUMP = 9, OP_RTI = 10,
               OP_UREG = 11, OP_CHK = 12, OP_ACC = 13, OP_POSTMOD = 14, OP_CNT = 15;

// the handler's requests, for the micro-ops after its clock
typedef struct packed {
    logic        pre_cond;
    logic        pcstk_set;
    logic [31:0] pcstk_v;
    logic        j, jpop;
    logic [31:0] target, popv;
    laddr_t      laddr;
    logic [7:0]  uq_u;
    logic [31:0] uq_d;
    logic        chk_im;
    logic [31:0] chk_imv;
    logic [1:0]  pmr;
    logic [1:0][2:0] pmi;
    logic [1:0][31:0] pmm, pms;
} xr_t;

xr_t         x_rq, rq_n;
logic [15:0] x_todo, todo_n;       // micro-ops still to run
logic [3:0]  x_k0;                 // the first of them
logic        x_last;               // ... is the last (XS_STEP)
logic        x_first;              // the instruction's first clock (state as before it)
logic        x_hclk;               // the handler runs this clock
logic        x_hcommit;            // ... and is applied at this edge
logic        x_exec_now;           // the first clock is applied (dbg_exec)
logic        x_seq;                // the clock's micro-ops are applied (EXEC, STEP, POST)
logic        x_commit;             // c is applied at this edge
logic        x_squash;
logic        x_fs_commit;          // idle, interrupt or squash: only the fetch step is applied
logic        x_stall;
logic        x_fast;               // the handler's accesses are internal and run this clock
logic        x_shift;              // the pc shift and ASTAT history of an executed instruction
logic        x_ext_req;            // X wants the external bus this clock
logic        x_portb;              // X uses port B at this edge
logic        x_pm_read;            // X reads program memory this clock
logic        x_pm_write;
logic        x_post_loads;         // XS_POST's R loads go to W at this edge
logic [31:0] redirect_pc;
logic        redirect;
logic        irq_ready;
logic [31:0] hv_pc, hv_daddr, hv_faddr, hv_nfaddr;   // the PC queue as the handler sees it

// the handler's view: after the shift in the first clock, Q's after it
always_comb
    if (xph == XS_EXEC) begin hv_pc = Q.daddr; hv_daddr = Q.faddr; hv_faddr = Q.nfaddr; hv_nfaddr = Q.nfaddr + 1; end
    else begin hv_pc = Q.pc; hv_daddr = Q.daddr; hv_faddr = Q.faddr; hv_nfaddr = Q.nfaddr; end

// an interrupt would be taken at this instruction's fetch step
assign irq_ready = !irq_entry && irq_check_en && ((Q.imask & (Q.irq_pending | dbg_irq_set)) != 0) &&
                   (Q.mode1 & MODE1_IRPTEN) != 0 && !Q.interrupt_active;

function automatic logic acc_fast(input acc_t a);
    acc_fast = is_dm1(a.addr) &&
               (a.kind == A_DM_RD || a.kind == A_DM_WR || a.kind == A_PM_RD32 || a.kind == A_PM_WR32) &&
               (a.kind == A_DM_WR || a.kind == A_PM_WR32 || a.dest_kind == 2'd0 ||
                (a.dest_kind == 2'd1 && a.dest[7:4] == 4'h0));
endfunction
function automatic logic acc_is_rd(input acc_kind_t k);
    acc_is_rd = k == A_DM_RD || k == A_PM_RD32 || k == A_PM_RD48;
endfunction

function automatic logic [3:0] first_op(input logic [15:0] t);
    first_op = 4'd15;
    for (int k = 15; k >= 0; k--) if (t[k]) first_op = 4'(k);
endfunction

// jump_to on the handler's view of the PC queue
task automatic op_jump(inout xc_t c, input logic j, input logic [31:0] t);
    if (j) begin c.s.nfaddr = t; c.s.delay_slot1 = hv_pc; c.s.delay_slot2 = hv_daddr; end
    else change_pc(c, t);
endtask

// a load's destination (v1 apply_load): R to W, PX here, other registers by op_ureg
task automatic apply_load(inout xc_t c, input logic k, input acc_t a, input logic [47:0] d);
    case (a.dest_kind)
    2'd0: begin c.lwe[k] = 1'b1; c.lr[k] = a.dest[3:0]; c.ld[k] = d[31:0]; end
    2'd1: if (a.dest[7:4] == 4'h0) begin c.lwe[k] = 1'b1; c.lr[k] = a.dest[3:0]; c.ld[k] = d[31:0]; end
          else set_ureg(c, a.dest, d[31:0]);
    2'd2: c.s.px = d;
    default: ;
    endcase
endtask

always_comb begin
    logic w_pend, needs, run_h, le, fz, endc;
    logic [31:0] pend;
    logic [15:0] ops, en;              // en: the micro-ops after the handler that run this clock
    logic [3:0]  k0;
    logic        src_rq;               // their arguments are x_rq's (XS_STEP, XS_POST), else the handler's
    logic        step_pm;              // the post-modify is from I now, not D's sum
    logic        a_irq, a_le, a_ci;    // interrupt entry, loop end, clear-interrupt this clock
    logic        p_push_pc, p_push_st, p_pop_loop, p_pop_pc, p_pop_st;   // ... and the stack operations they need
    logic [31:0] irq_pend, le_cur;
    c = '0;
    c.s = Q;
    c.c_mode1 = Q.mode1;
    c.c_astat = Q.astat;
    rq_n = x_rq; todo_n = x_todo;
    x_first = 1'b0; x_hclk = 1'b0; x_seq = 1'b0; x_commit = 1'b0; x_squash = 1'b0; x_fs_commit = 1'b0;
    x_stall = 1'b0; x_fast = 1'b0; x_shift = 1'b0; x_go = 1'b0; redirect = 1'b0; redirect_pc = 32'h0;
    x_ext_req = 1'b0; x_portb = 1'b0; x_pm_read = 1'b0; x_pm_write = 1'b0; x_post_loads = 1'b0;
    run_h = 1'b0; endc = 1'b0; k0 = 4'd0; en = 16'h0; src_rq = 1'b0; step_pm = 1'b0;
    a_irq = 1'b0; a_le = 1'b0; a_ci = 1'b0; irq_pend = Q.irq_pending; le_cur = Q.curlcntr;
    p_push_pc = 1'b0; p_push_st = 1'b0; p_pop_loop = 1'b0; p_pop_pc = 1'b0; p_pop_st = 1'b0;
    w_pend = w_on;
    le = (Q.stky & LSEM) == 0 && Q.daddr == Q.laddr.addr;

    // ---------------------------------------------------------------- what runs this clock
    if (x_valid && !booting) case (xph)
    XS_EXEC: begin
        // W's flags land at this edge: an instruction that reads ASTAT or STKY waits a clock
        needs = x_dec.needs_astat || (le && Q.laddr.loop_type == 2'd0) || irq_ready;
        if ((w_pend && needs) || (serial && e_busy) || swap_req != 0) x_stall = 1'b1;
        else begin
            // fetch_step: interrupts, then idle, then the pc shift. The vector's first instruction
            // skips the interrupt part: MAME takes the interrupt and runs it in one step
            pend = irq_entry ? Q.irq_pending : (Q.irq_pending | dbg_irq_set);
            c.s.irq_pending = pend;
            irq_pend = pend;
            if (!irq_entry && irq_check_en && pend != 0) begin
                c.s.idle = 1'b0;
                a_irq = irq_take(pend);
            end
            if (a_irq) begin
                x_fs_commit = 1'b1; x_squash = 1'b1;
                redirect = 1'b1; redirect_pc = irq_vector(pend);
            end else if (c.s.idle) x_fs_commit = 1'b1;
            else if (x_pc != Q.daddr) begin
                x_fs_commit = 1'b1; x_squash = 1'b1;
                redirect = 1'b1; redirect_pc = Q.daddr;
            end else begin
                x_first = 1'b1; x_shift = 1'b1; x_seq = 1'b1;
                a_le = le;
                rq_n.pre_cond = cond_on(Q.astat, x_op[37:33]);
                todo_n = 16'h0;
                if (ci_needed(x_op, 1'b1)) begin todo_n[OP_CLEARINT] = 1'b1; todo_n[OP_HANDLER] = 1'b1; end   // whatever the condition
                else if (le && loop_conflict(x_op)) todo_n[OP_HANDLER] = 1'b1;
                else run_h = 1'b1;
            end
        end
    end
    XS_STEP: begin
        k0 = x_k0;
        if (x_todo == 16'h0) x_seq = 1'b1;
        else if (k0 == 4'(OP_HANDLER) && w_pend && x_dec.needs_astat) x_stall = 1'b1;
        else begin
            x_seq = 1'b1;
            todo_n[k0] = 1'b0;
            src_rq = 1'b1;
            case (k0)
            4'(OP_CLEARINT): a_ci = ci_needed(x_op, x_rq.pre_cond);
            4'(OP_HANDLER):  begin run_h = 1'b1; src_rq = 1'b0; end   // its micro-ops take its own requests
            4'(OP_CHK): begin
                // check_interrupts, then the IMASK write that asked for it
                a_irq = irq_take(Q.irq_pending);
                if (x_rq.chk_im) c.s.imask = x_rq.chk_imv;
                rq_n.chk_im = 1'b0;
            end
            4'(OP_POSTMOD), 4'(OP_CNT): begin
                en[OP_POSTMOD] = x_rq.pmr != 2'b00; en[OP_CNT] = 1'b1; step_pm = 1'b1;
                todo_n[OP_POSTMOD] = 1'b0; todo_n[OP_CNT] = 1'b0;
            end
            default: en[k0] = 1'b1;
            endcase
        end
    end
    XS_ACC: begin
        acc_t a;
        a = x_acc[x_cur];
        if (is_pm(a.addr) && acc_is_rd(a.kind)) x_pm_read = 1'b1;
        else if (is_pm(a.addr)) x_pm_write = 1'b1;
        else if (!is_dm1(a.addr) && a.addr >= 32'h100) x_ext_req = 1'b1;
        else if (!is_dm1(a.addr) && e_busy) x_stall = 1'b1;       // IOP: the DMA state settles first
    end
    XS_WAIT: begin
        acc_t a;
        a = x_acc[x_cur];
        if (!is_dm1(a.addr) && !is_pm(a.addr) && a.addr < 32'h100 && !acc_is_rd(a.kind)) begin
            c.iow = 1'b1; c.iow_a = a.addr[7:0]; c.iow_d = a.wdata[31:0];
            x_commit = 1'b1;
        end
    end
    XS_POST: begin
        // the loads: R to W; another register (one at most) by op_ureg, then the post-modifies
        x_seq = 1'b1;
        x_post_loads = 1'b1;
        todo_n[OP_ACC] = 1'b0;
        src_rq = 1'b1;
        for (int k = 0; k < 2; k++)
            if (k < x_n && acc_is_rd(x_acc[k].kind)) apply_load(c, 1'(k), x_acc[k], x_rdata[k]);
        if (c.ureq) begin todo_n[OP_UREG] = 1'b1; rq_n.uq_u = c.uq_u; rq_n.uq_d = c.uq_d; end
        else if (first_op(todo_n) >= 4'(OP_POSTMOD)) begin
            en[OP_POSTMOD] = x_rq.pmr != 2'b00; en[OP_CNT] = 1'b1;
            todo_n[OP_POSTMOD] = 1'b0; todo_n[OP_CNT] = 1'b0;
        end
    end
    default: ;
    endcase

    // ---------------------------------------------------------------- each micro-op once, in order
    if (a_irq) irq_core(c, irq_pend, p_push_st);
    p_push_pc = a_irq;
    if (x_shift) begin c.s.pc = Q.daddr; c.s.daddr = Q.faddr; c.s.faddr = Q.nfaddr; c.s.nfaddr = Q.nfaddr + 1; end
    // the loop end (sharc.cpp:1286-1335), after the pc shift: the PC is Q.daddr
    if (a_le) begin
        logic cnd;
        if (Q.laddr.loop_type == 2'd0) begin
            logic [31:0] a;
            logic [4:0]  cc;
            a = (Q.daddr - Q.pcstk > 2) ? Q.astat_old_old : Q.astat;
            cc = Q.laddr.code;
            cnd = cc == 5'h0f ? Q.curlcntr == 1 : cc == 5'h1f ? 1'b0 : cond_on(a, cc);
        end else begin
            c.s.curlcntr = Q.curlcntr - 1;
            cnd = Q.curlcntr == 1;
            le_cur = 32'h0;
        end
        if (cnd) begin p_pop_loop = 1'b1; p_pop_pc = 1'b1; end
        else change_pc(c, Q.pcstk);
    end
    // clear_int (a jump's CI bit)
    if (a_ci) begin
        p_pop_st = Q.active_irq_num >= 6 && Q.active_irq_num <= 8;
        c.s.interrupt_active = 1'b0;
        c.s.irptl = Q.irptl & ~(32'h1 << Q.active_irq_num[4:0]);
    end

    if (run_h) begin
        x_hclk = 1'b1;
        c.usrc = get_ureg(c, usrc_sel(x_op));
        dag_ports(c);
        execute_op(c, x_op, (xph == XS_EXEC) ? rq_n.pre_cond : x_rq.pre_cond);
        // the accesses' post-modifies join the handler's
        for (int k = 0; k < 2; k++)
            if (k < c.n && c.a[k].post_mod) begin
                c.pmr[c.a[k].post_pm] = 1'b1; c.pmi[c.a[k].post_pm] = c.a[k].post_i;
                c.pmm[c.a[k].post_pm] = c.a[k].post_m; c.pms[c.a[k].post_pm] = c.a[k].post_s;
            end
        ops = 16'h0;
        ops[OP_PUSH_LOOP] = c.r_push_loop; ops[OP_POP_LOOP] = c.r_pop_loop; ops[OP_DO] = c.r_do;
        ops[OP_PUSH_ST] = c.r_push_status; ops[OP_POP_ST] = c.r_pop_status;
        ops[OP_PUSH_PC] = c.r_push_pc; ops[OP_POP_PC] = c.r_pop_pc; ops[OP_JUMP] = c.r_jump;
        ops[OP_RTI] = c.r_rti; ops[OP_UREG] = c.ureq; ops[OP_ACC] = c.n != 0;
        ops[OP_POSTMOD] = c.pmr != 0; ops[OP_CNT] = 1'b1;
        rq_n.pcstk_set = c.r_pcstk; rq_n.pcstk_v = c.r_pcstk_v;
        rq_n.j = c.r_j; rq_n.jpop = c.r_jpop; rq_n.target = c.r_target; rq_n.laddr = c.r_laddr;
        rq_n.uq_u = c.uq_u; rq_n.uq_d = c.uq_d;
        rq_n.pmr = c.pmr; rq_n.pmi = c.pmi; rq_n.pmm = c.pmm; rq_n.pms = c.pms;
        // op_fuse: the leading micro-ops that write other state than the handler's and each other's
        fz = 1'b1;
        for (int k = OP_PUSH_LOOP; k <= OP_CNT; k++)
            if (ops[k]) begin
                logic ok;
                case (k)
                OP_PUSH_PC: ok = 1'b1;
                OP_POP_PC:  ok = !ops[OP_PUSH_PC];
                OP_JUMP:    ok = 1'b1;
                OP_UREG:    ok = ureg_simple(c.uq_u);
                OP_ACC:     ok = x_aok;
                OP_POSTMOD, OP_CNT: ok = 1'b1;
                default:    ok = 1'b0;
                endcase
                if (fz && ok) begin
                    if (k == OP_ACC) x_fast = 1'b1;
                    else en[k] = 1'b1;
                end else begin fz = 1'b0; todo_n[k] = 1'b1; end
            end
    end

    // the stack operations: the loop end's pops come before the handler's compute point
    begin
        logic cp0;
        cp0 = c.cp;
        if (p_pop_loop || p_pop_pc) c.cp = 1'b0;
        if (en[OP_PUSH_LOOP]) op_push_loop(c);
        if (en[OP_POP_LOOP] || p_pop_loop) op_pop_loop(c, p_pop_loop ? le_cur : Q.curlcntr);
        if (en[OP_DO]) c.s.laddr = x_rq.laddr;
        if (en[OP_PUSH_ST] || p_push_st) op_push_status(c);
        if (en[OP_POP_ST] || p_pop_st) op_pop_status(c);
        if (en[OP_PUSH_PC] || p_push_pc)
            op_push_pc(c, p_push_pc ? 1'b1 : src_rq ? x_rq.pcstk_set : c.r_pcstk,
                          p_push_pc ? (Q.idle ? Q.pc + 1 : Q.daddr) : src_rq ? x_rq.pcstk_v : c.r_pcstk_v);
        if (en[OP_POP_PC] || p_pop_pc) begin
            if (src_rq) rq_n.popv = Q.pcstk;
            op_pop_pc(c);
        end
        c.cp = cp0;
    end
    if (en[OP_JUMP])
        op_jump(c, src_rq ? x_rq.j : c.r_j,
                   src_rq ? (x_rq.jpop ? x_rq.popv : x_rq.target) : (c.r_jpop ? Q.pcstk : c.r_target));
    if (en[OP_RTI]) begin c.s.interrupt_active = 1'b0; todo_n[OP_CHK] = 1'b1; end
    // the handler's own write: only the forms with no micro-op before it ask for one (no fusion chain)
    if (src_rq ? en[OP_UREG] : (run_h && c.ureq && ureg_simple(c.uq_u))) begin
        op_ureg(c, src_rq ? x_rq.uq_u : c.uq_u, src_rq ? x_rq.uq_d : c.uq_d);
        if (src_rq && x_rq.uq_u == 8'h7d) begin todo_n[OP_CHK] = 1'b1; rq_n.chk_im = 1'b1; rq_n.chk_imv = x_rq.uq_d; end
    end
    if (en[OP_POSTMOD])
        for (int g = 0; g < 2; g++)
            if (src_rq ? x_rq.pmr[g] : c.pmr[g]) begin
                logic [2:0] i;
                i = src_rq ? x_rq.pmi[g] : c.pmi[g];
                c.pwe[g] = 1'b1; c.pi[g] = i;
                c.pd[g] = step_pm ? pm_wrap(1'(g), i, dgx_q[{1'(g), 2'd0}] + x_rq.pmm[g]) : x_pd[g];
            end
    if (en[OP_CNT]) post_counters(c);

    // the instruction completes when nothing is left; the fmul slow path and FAVG hold the handler,
    // and the next DMA quantum waits for the last. The handler's first clock ends the instruction
    // by its class (dec_t.one) and its accesses (x_aok), not by what it asked for: that keeps the
    // condition out of the clock's control. XS_STEP's from x_last, XS_POST's from its loads
    begin
        logic ul;
        ul = 1'b0;
        for (int k = 0; k < 2; k++)
            if (k < x_n && acc_is_rd(x_acc[k].kind) && x_acc[k].dest_kind == 2'd1 && x_acc[k].dest[7:4] != 4'h0) ul = 1'b1;
        case (xph)
        XS_EXEC: endc = run_h && x_dec.one && x_aok;
        XS_STEP: endc = x_last;
        XS_POST: endc = !ul;
        default: endc = 1'b0;
        endcase
    end
    endc = endc && x_seq;
    if (x_seq && ((run_h && x_busy) || ((DMA_LOCK || serial) && endc && e_busy))) x_stall = 1'b1;
    if (x_stall) begin x_seq = 1'b0; x_first = 1'b0; endc = 1'b0; end
    x_commit = x_commit || x_seq;
    x_go = endc;
    if (x_go && c.n == 2'd2 && x_fast) x_portb = 1'b1;
end
assign x_hcommit = x_hclk && x_seq;

// benches: the decoded universal-register write is the handler's own
always_ff @(posedge clk)
    if (BENCH && ce && x_hcommit && (x_uw != c.uwe || (x_uw && (x_dec.uw_r != c.ur || x_uw_d != c.ud))))
        $error("X: %06X ureg write decoded %0d R%0d %08X, handler %0d R%0d %08X", x_pc[23:0],
               x_uw, x_dec.uw_r, x_uw_d, c.uwe, c.ur, c.ud);
// benches: an instruction its class ends in the first clock has nothing left
always_ff @(posedge clk)
    if (BENCH && ce && x_go && todo_n != 16'h0)
        $error("X: %06X ends with micro-ops %04X left", x_pc[23:0], todo_n);
assign x_exec_now = x_first && x_seq;

// SUBSET: an instruction outside it executes (HARDWARE_NOTES "Program census": none in the program)
logic x_unsup;
assign x_unsup = x_op[47:45] == 3'b001 || (x_dec.comp_on && !x_dec.shimm && comp_unsup(x_op[22:0])) ||
                 (x_dec.shimm && shift_unsup(x_op[21:16]));
always_ff @(posedge clk)
    if (reset) unsup <= 1'b0;
    else if (SUBSET && ce && x_exec_now && x_unsup) begin
        unsup <= 1'b1;
        if (BENCH) $error("SHARC: %06X %012X is outside the subset (SUBSET)", x_pc[23:0], x_op);
    end

// the DAG arrays' write port: a bench load (dbg_wsel 2-17: I M L B of DAG1, of DAG2, then the
// alternates), or X's post-modifies and universal-register write (B writes I too)
always_comb begin
    for (int a = 0; a < 8; a++) begin dg_we[a] = 1'b0; dg_wa[a] = 4'h0; dg_wd[a] = 32'h0; end
    if (dbg_we && dbg_wsel >= 8'd2 && dbg_wsel <= 8'd17) begin
        logic [3:0] sl;
        sl = 4'(dbg_wsel - 8'd2);
        dg_we[sl[2:0]] = 1'b1;
        dg_wa[sl[2:0]] = {dbk(sl[2], dbg_widx[2:0]) ^ sl[3], dbg_widx[2:0]};
        dg_wd[sl[2:0]] = dbg_wdata[31:0];
    end else if (!reset && ce && run && !booting && x_commit) begin
        for (int g = 0; g < 2; g++)
            if (c.pwe[g]) begin
                dg_we[g * 4] = 1'b1; dg_wa[g * 4] = {dbk(1'(g), c.pi[g]), c.pi[g]}; dg_wd[g * 4] = c.pd[g];
            end
        if (c.dwe) begin
            dg_we[{c.dg, c.dk}] = 1'b1; dg_wa[{c.dg, c.dk}] = {dbk(c.dg, c.di), c.di}; dg_wd[{c.dg, c.dk}] = c.dd;
            if (c.dk == 2'd3) begin
                dg_we[{c.dg, 2'd0}] = 1'b1; dg_wa[{c.dg, 2'd0}] = {dbk(c.dg, c.di), c.di}; dg_wd[{c.dg, 2'd0}] = c.dd;
            end
        end
    end
end
// X reads the register XS_STEP's post-modify names, or the universal register's
logic [7:0] x_usel;
assign x_usel = usrc_sel(x_op);
always_comb begin
    logic hclk;
    // D latches only at an instruction's end, which in XS_EXEC is the handler's clock: the phase
    // is enough for forwarding; the R file's write adds x_hcommit
    hclk = xph == XS_EXEC || (xph == XS_STEP && x_k0 == 4'(OP_HANDLER));
    x_uw = x_valid && x_dec.uw && hclk && (x_op[47:44] != 4'b0111 || cond_on(Q.astat, x_op[35:31]));
    x_uw_d = (x_op[47:44] == 4'b0111) ? get_ureg(c, x_usel) : x_op[31:0];
end
always_comb
    for (int g = 0; g < 2; g++)
        dgx_i[g] = (xph == XS_STEP && (x_k0 == 4'(OP_POSTMOD) || x_k0 == 4'(OP_CNT))) ? x_rq.pmi[g] : x_usel[2:0];

// the PC stack array in MLAB: one write port (X, or a bench load); one read port, for a pop
// (PCSTKP - 2) or a PCSTKP write's new top
logic        pcs_we;
logic [4:0]  pcs_wa, pcs_ra;
logic [31:0] pcs_wd;
always_comb begin
    pcs_we = dbg_we && dbg_wsel == 8'd29;
    pcs_wa = dbg_widx[4:0]; pcs_wd = dbg_wdata[31:0];
    if (!pcs_we && !reset && ce && run && !booting && (x_commit || x_fs_commit) && c.psw) begin
        pcs_we = 1'b1; pcs_wa = c.psi; pcs_wd = c.psd;
    end
    pcs_ra = (xph == XS_STEP && x_k0 == 4'(OP_UREG) && x_rq.uq_u == 8'h65) ? 5'(x_rq.uq_d[4:0] - 5'd1)
                                                                          : 5'(Q.pcstkp - 32'd2);
end
sharc2_lutram #(.AW(5), .DW(32)) u_pcs (.clk, .we(pcs_we), .wa(pcs_wa), .wd(pcs_wd), .ra(pcs_ra), .rd(pcs_rd));

// the loop stacks (LCNTR, LADDR) and the status stack (MODE1, ASTAT) in MLAB: one write port each
// (X at LSTKP - 1 or STATUS_STKP, or a bench load), one read port: a loop push reads LSTKP + 1 and
// LSTKP (it runs in an XS_STEP clock of its own), a pop LSTKP - 2, the boot entry 0; a status pop
// STATUS_STKP - 1
logic        st_go;
logic [2:0]  lc_ra, la_ra, ls_wa, ss_wa;
logic        lc_we, la_we, ss_we;
logic [31:0] lc_wd, la_wd, ssm_wd, ssa_wd;
assign st_go = !reset && ce && run && !booting && (x_commit || x_fs_commit);
always_comb begin
    logic push;
    push = xph == XS_STEP && x_k0 == 4'(OP_PUSH_LOOP);
    lc_ra = boot_done ? 3'd0 : push ? 3'(Q.lstkp + 32'd1) : 3'(Q.lstkp - 32'd2);
    la_ra = push ? 3'(Q.lstkp) : 3'(Q.lstkp - 32'd2);
    ls_wa = 3'(Q.lstkp - 32'd1);
    ss_wa = 3'(Q.status_stkp);
    lc_we = st_go && c.lcw; lc_wd = c.lcd;
    la_we = st_go && c.law; la_wd = c.lad;
    ss_we = st_go && c.ssw; ssm_wd = c.ssm; ssa_wd = c.ssa;
    if (dbg_we && (dbg_wsel == 8'd30 || dbg_wsel == 8'd31 || dbg_wsel == 8'd36 || dbg_wsel == 8'd37)) begin
        lc_we = dbg_wsel == 8'd30; la_we = dbg_wsel == 8'd31;
        ls_wa = dbg_widx[2:0]; ss_wa = dbg_widx[2:0];
        lc_wd = dbg_wdata[31:0]; la_wd = dbg_wdata[31:0]; ssm_wd = dbg_wdata[31:0]; ssa_wd = dbg_wdata[31:0];
        ss_we = 1'b0;
    end
end
logic ssm_we, ssa_we;
assign ssm_we = ss_we || (dbg_we && dbg_wsel == 8'd36);
assign ssa_we = ss_we || (dbg_we && dbg_wsel == 8'd37);
sharc2_lutram #(.AW(3), .DW(32)) u_lc (.clk, .we(lc_we), .wa(ls_wa), .wd(lc_wd), .ra(lc_ra), .rd(lc_rd));
sharc2_lutram #(.AW(3), .DW(32)) u_la (.clk, .we(la_we), .wa(ls_wa), .wd(la_wd), .ra(la_ra), .rd(la_rd));
sharc2_lutram #(.AW(3), .DW(32)) u_ssm (.clk, .we(ssm_we), .wa(ss_wa), .wd(ssm_wd), .ra(3'(Q.status_stkp - 32'd1)), .rd(ssm_rd));
sharc2_lutram #(.AW(3), .DW(32)) u_ssa (.clk, .we(ssa_we), .wa(ss_wa), .wd(ssa_wd), .ra(3'(Q.status_stkp - 32'd1)), .rd(ssa_rd));

// ------------------------------------------------------------------------------------------
// F and D control
// ------------------------------------------------------------------------------------------

logic        d_hazard, d_block;
logic [4:0]  dbg_hz /*verilator public_flat_rd*/;
// benches: the pipeline's state for profiles ({xph, exec, squash, X valid, X stall, X busy, DMA busy,
// D valid, D hazard}) and X's PC
logic [10:0] dbg_prof /*verilator public_flat_rd*/;
logic [31:0] dbg_xpc /*verilator public_flat_rd*/;
assign dbg_prof = {xph, x_exec_now, x_squash, x_valid, x_stall, x_busy, e_busy, d_valid, d_hazard};
assign dbg_xpc = x_pc;
// D's slow-unit op (FLOAT, FIX, RECIPS, MIN, FAVG, ...) reads a register X's instruction names
wire d_slow_x = (d_ci.mc || d_ci.avg) && x_valid &&
                ((xw_wr[0] && (xw_r0 == d_dec.i_ax || xw_r0 == d_dec.i_ay)) ||
                 (xw_wr[1] && (xw_r1 == d_dec.i_ax || xw_r1 == d_dec.i_ay)) ||
                 (x_dec.uw && (x_dec.uw_r == d_dec.i_ax || x_dec.uw_r == d_dec.i_ay)));
logic [31:0] pred_next, f_next, f_addr;
logic        d_keep;

always_comb begin
    logic [31:0] qd, qf, qn, lend, ltop, lcnt;
    logic        lsem;
    logic [1:0]  ltype;
    // MAME's queue after this clock's X
    // from the registered state: an X change of this clock is seen a clock later (the queue's
    // window covers the shift; a loop or jump change mispredicts once, and X squashes)
    qd = Q.daddr; qf = Q.faddr; qn = Q.nfaddr;
    lend = Q.laddr.addr; ltop = Q.pcstk; lcnt = Q.curlcntr; ltype = Q.laddr.loop_type;
    lsem = (Q.stky & LSEM) != 0;
    if (!lsem && d_pc == lend && (ltype == 2'd0 || lcnt != 1)) pred_next = ltop;
    else if (d_pc == qd) pred_next = qf;
    else if (d_pc == qf) pred_next = qn;
    else pred_next = d_pc + 1;

    // D's operands wait for X's W results; the slow unit for its previous op
    // the slow unit loads its operands at D without X's results of the clock (fwd_d): an op that
    // reads a register X's instruction names waits a clock for it
    d_hazard = (x_valid && late_hit(pm_q, x_late)) || d_mc_wait || d_slow_x ||
               (x_valid && x_dec.wdag && d_dec.rdag);
    // benches: the hazard's causes (sim/sharc2_tb +pipe)
    dbg_hz = {x_valid && late_hit(pm_q, x_late_ld), x_valid && x_dec.wdag && d_dec.rdag, d_slow_x, d_mc_wait,
              x_valid && late_hit(pm_q, x_late)};
    // X takes D's instruction at this edge
    d_block = !d_valid || d_hazard || swap_req != 0 || (x_commit && c.swap != 0) ||
              x_pm_read || x_pm_write || booting ||
              (serial && (x_valid || xr_we != 0 || w_lwe != 0 || w_on || ww_we != 0 || e_busy || e_start));
    d_go = !d_block && (!x_valid || x_go) && !x_squash;
    d_keep = d_valid && !d_go && !(redirect && (x_squash || d_pc != redirect_pc));

    // the fetch address assumes D goes: a D that waits holds pm_q instead (pm_en), so that d_go
    // reaches the RAM's read enable and not its address
    if (redirect && (x_squash || !d_valid || d_pc != redirect_pc)) f_addr = redirect_pc;
    else if (d_valid) f_addr = pred_next;
    else f_addr = (x_valid && xph == XS_EXEC) ? Q.faddr : Q.daddr;
    f_next = d_keep ? d_pc : f_addr;
end

// D: an unconditional data-memory load into R whose address D has (the I and I + immediate forms
// with one access) reads DM port B while it waits in D (ld_rd), so that when it goes to X (ld_go) the
// next instruction takes the data at the following edge (latency 1) instead of from W. Not while
// X's instruction may write data memory or use port B, nor while the DMA engine has port B, nor in
// serial (bench) mode. ld_rd does not depend on d_go, nor the engine on ld_rd: neither path goes
// through D's issue logic.
logic        el_c, ld_rd, ld_go;
logic [31:0] el_a;
logic [DMAW-1:0] el_lo;            // el_a's low bits (0x28000's are 0), from the low bits alone: port B's address
logic [3:0]  el_r;
always_comb begin
    logic [47:0] op;
    logic        t_cond;
    op = pm_q;
    t_cond = op[37:33] == 5'h1F;
    el_c = 1'b0; el_a = d_dI[0]; el_lo = d_dI[0][DMAW-1:0]; el_r = op[26:23];
    casez (op[47:39])
    9'b0110?????: if (!op[40] && !op[39] && t_cond) begin
        el_c = 1'b1;
        if (!op[38]) begin el_a = d_dI[0] + d_imm[0]; el_lo = d_dI[0][DMAW-1:0] + d_imm[0][DMAW-1:0]; end
    end
    9'b0100?????, 9'b0101?????: if (!op[32] && !op[31] && op[30:27] == 4'h0 && t_cond) begin
        el_c = 1'b1;
        if (!op[44]) begin el_a = d_dI[0] + d_dM[0]; el_lo = d_dI[0][DMAW-1:0] + d_dM[0][DMAW-1:0]; end
    end
    9'b1000?????: if (!op[32] && !op[31] && t_cond) el_c = 1'b1;
    9'b101??????: if (!op[44] && !op[40] && op[39:36] == 4'h0) begin
        el_c = 1'b1; el_a = d_dI[0] + d_imm[0]; el_lo = d_dI[0][DMAW-1:0] + d_imm[0][DMAW-1:0]; el_r = op[35:32];
    end
    default: ;
    endcase
    // port B reads el_lo for any load of these forms (a read outside block 1 is not used); only
    // whether X takes it depends on the whole address
    ld_rd = d_valid && el_c && !serial && !(x_valid && (x_dmw || x_pb)) && !e_portb_do;
    ld_go = d_go && ld_rd && el_a >= 32'h28000 && el_a < 32'h28000 + DM_WORDS;
end
// the early load's data, and whether R[r] takes it at this edge (its instruction commits now; it
// beats X's other results for r, as the load is applied after the compute)
assign el_d = x_ef ? dm_qb : x_eld;
assign el_fwd = x_valid && x_el && x_hcommit;

always_comb begin
    pm_ra_c = 15'(f_addr - 32'h20000);
    pm_en = ce && !d_keep;
    if (ce && x_pm_read) begin pm_ra_c = 15'(x_acc[x_cur].addr - 32'h20000); pm_en = 1'b1; end
end

// ------------------------------------------------------------------------------------------
// Memory ports
// ------------------------------------------------------------------------------------------

assign e_stp = e_eff_step(e_sel[0], e_step);
assign e_ad = e_addr(e_sel[0], e_stp);

always_comb begin
    dma_a_c = dma_a_q; dma_we_c = 1'b0; dma_wd_c = 32'h0;
    dmb_a_c = dmb_a_q; dmb_we_c = 1'b0; dmb_wd_c = 32'h0;
    pm_we = 1'b0; pm_wa = 15'h0; pm_wd = 48'h0;
    if (dbg_dm_we) begin dma_a_c = dbg_dm_addr; dma_we_c = 32'(dbg_dm_addr) < DM_WORDS; dma_wd_c = dbg_dm_wdata; end
    else if (ce) begin
        if (x_hcommit && x_fast && c.n != 0) begin
            dma_a_c = 15'(c.a[0].addr - 32'h28000);
            dma_we_c = !acc_is_rd(c.a[0].kind); dma_wd_c = c.a[0].wdata[31:0];
            if (c.n == 2'd2) begin
                dmb_a_c = 15'(c.a[1].addr - 32'h28000);
                dmb_we_c = !acc_is_rd(c.a[1].kind); dmb_wd_c = c.a[1].wdata[31:0];
            end
        end else if (xph == XS_ACC && x_valid && is_dm1(x_acc[x_cur].addr)) begin
            dma_a_c = 15'(x_acc[x_cur].addr - 32'h28000);
            dma_we_c = !acc_is_rd(x_acc[x_cur].kind); dma_wd_c = x_acc[x_cur].wdata[31:0];
        end
    end
    // PM writes: X, then the engine's packed words, then boot (below)
    if (ce && x_pm_write && x_valid && xph == XS_ACC) begin
        pm_we = 1'b1; pm_wa = 15'(x_acc[x_cur].addr - 32'h20000);
        pm_wd = (x_acc[x_cur].kind == A_PM_WR48) ? x_acc[x_cur].wdata : x_acc[x_cur].wdata;
    end else if (ce && e_pmw) begin
        pm_we = 1'b1; pm_wa = e_pmw_a; pm_wd = e_pmw_d;
    end else if (boot_pm_we) begin
        pm_we = 1'b1; pm_wa = boot_pm_wa; pm_wd = boot_pm_wd;
    end
    if (ce && ld_rd) begin dmb_a_c = 15'(el_lo); dmb_we_c = 1'b0; dmb_wd_c = 32'h0; end
    if (ce && e_portb_do) begin
        dmb_a_c = e_portb_a; dmb_we_c = e_portb_we; dmb_wd_c = e_portb_wd;
    end
    if (boot_dm_we) begin dmb_a_c = boot_dm_wa; dmb_we_c = 1'b1; dmb_wd_c = 32'h0; end
end

// ------------------------------------------------------------------------------------------
// External bus: X or the engine or boot
// ------------------------------------------------------------------------------------------

assign ext_req   = xb_req || eb_req || bb_req;
assign ext_we    = xb_req ? xb_we : eb_req ? eb_we : 1'b0;
assign ext_addr  = xb_req ? xb_addr : eb_req ? eb_addr : bb_addr;
assign ext_wdata = xb_req ? xb_wdata : eb_wdata;

// ------------------------------------------------------------------------------------------
// X sequencing and commit
// ------------------------------------------------------------------------------------------

function automatic logic [31:0] mask_apply(input logic [31:0] v, input logic [63:0] m);
    mask_apply = (v & ~m[63:32]) | m[31:0];
endfunction

always_ff @(posedge clk) begin
    irq_prev <= irq_in;
    if (reset) begin
        d_valid <= 1'b0;
        x_valid <= 1'b0;
        xph <= XS_EXEC;
        w_lwe <= 2'b00; xr_we <= 3'b000;
        swap_req <= '0;
        bk <= 6'h0;
        xb_req <= 1'b0;
        irq_entry <= 1'b0;
        Q.idle <= 1'b0;
        run <= 1'b0;
    end else if (ce && run && !booting) begin
        // ---------------------------------------------------------------- R
        begin
            logic [31:0] nr [16];
            for (int k = 0; k < 16; k++) nr[k] = rf[k];
            if (xr_we[0]) nr[xr_r0] = xr_d0;
            if (xr_we[1]) nr[xr_r1] = xr_d1;
            if (xr_we[2]) nr[xr_ru] = xr_du;
            if (ww_we[0] && !w_kill[ww_r0]) nr[ww_r0] = ww_d0;
            if (ww_we[1] && !w_kill[ww_r1]) nr[ww_r1] = ww_d1;
            if (ww_we[2] && !w_kill[ww_r2]) nr[ww_r2] = ww_d2;
            if (w_lwe[0]) nr[w_lr[0]] = w_ld[0];
            if (w_lwe[1]) nr[w_lr[1]] = w_ld[1];
            for (int k = 0; k < 16; k++) rfp[{rbk(4'(k)), 4'(k)}] <= nr[k];
            xr_we <= x_hcommit ? {x_uw, xw_we} : 3'b000;
            xr_r0 <= xw_r0; xr_r1 <= xw_r1; xr_ru <= x_dec.uw_r;
            xr_d0 <= xw_d0; xr_d1 <= xw_d1; xr_du <= x_uw_d;
        end

        // ---------------------------------------------------------------- sequencer state, ASTAT, STKY
        begin
            logic [31:0] a, s;
            q_t n;
            a = astat_fwd; s = stky_fwd;
            n = Q;
            if (x_commit || x_fs_commit) begin
                a = mask_apply(a, c.apre); s = mask_apply(s, c.spre);
                if (x_hcommit && c.compute) begin
                    a = (a & ~x_aclr) | x_aset; s = s | x_sset;
                end
                a = mask_apply(a, c.apost); s = mask_apply(s, c.spost);
                n = c.s;
                if (x_shift && x_seq) begin
                    n.astat_old_old_old = Q.astat_old_old;
                    n.astat_old_old = Q.astat_old;
                    n.astat_old = astat_fwd;
                end else begin
                    n.astat_old_old_old = Q.astat_old_old_old;
                    n.astat_old_old = Q.astat_old_old;
                    n.astat_old = Q.astat_old;
                end
            end
            n.astat = a; n.stky = s;
            if (x_commit && c.iow) iop_write(n, c.iow_a, c.iow_d);
            // DMA completions of this edge
            n.irptl = n.irptl | e_irq_set;
            n.irq_pending = n.irq_pending | (e_irq_set & Q.imask);
            Q <= n;
        end
        if (x_hcommit && c.compute) begin
            if (x_mrf_we) mrf <= x_mr_d;
            if (x_mrb_we) mrb <= x_mr_d;
        end
        if (x_hcommit) begin
            x_c_compute <= c.compute; x_c_shimm <= c.shimm;
            x_c_mode1 <= c.c_mode1; x_c_astat <= c.c_astat;
        end

        // ---------------------------------------------------------------- DAG, PC stack
        if (x_commit) begin
            if (c.swap != 0) swap_req <= c.swap;
        end

        // ---------------------------------------------------------------- register-set swaps
        if (swap_req != 0 && !x_valid && xr_we == 0 && w_lwe == 0 && !w_on && ww_we == 0) begin
            bk <= bk ^ swap_req;
            swap_req <= '0;
        end

        // ---------------------------------------------------------------- W
        w_lwe <= 2'b00;
        if (x_go) begin
            w_kill <= (x_hcommit ? (x_uw ? bit16(x_dec.uw_r) : 16'h0) : x_kill);
            if (x_fast)
                for (int k = 0; k < 2; k++) begin
                    w_lwe[k] <= k < c.n && acc_is_rd(c.a[k].kind);
                    w_lr[k] <= c.a[k].dest[3:0];
                    w_lsrc[k] <= (k == 0 && x_el) ? 2'd3 : k[1:0];
                end
            w_ebuf <= el_d;
        end
        if (x_seq && x_post_loads) begin
            w_lwe <= c.lwe; w_lr <= c.lr; w_lbuf <= c.ld;
            w_lsrc <= {2'd2, 2'd2};
        end

        // ---------------------------------------------------------------- X
        // R written by the instruction's set_ureg after its compute: W's late results lose to it
        if (x_hcommit) x_kill <= x_uw ? bit16(x_dec.uw_r) : 16'h0;
        if (x_seq) begin
            logic [3:0]  k;
            logic [15:0] rest;
            x_rq <= rq_n; x_todo <= todo_n;
            k = first_op(todo_n);
            x_k0 <= k;
            rest = todo_n & ~((k == 4'(OP_POSTMOD) || k == 4'(OP_CNT)) ? 16'hC000 : 16'h1 << k);
            x_last <= todo_n == 16'h0 || (k != 4'(OP_ACC) && rest == 16'h0 && k != 4'(OP_RTI) &&
                                         !(k == 4'(OP_UREG) && rq_n.uq_u == 8'h7d));
        end
        if (x_hcommit && todo_n[OP_ACC]) begin x_acc <= c.a; x_n <= c.n; x_cur <= 1'b0; end
        if (x_seq && !x_go) xph <= (first_op(todo_n) == 4'(OP_ACC)) ? XS_ACC : XS_STEP;
        // an external access asks for the bus in the handler's clock, not in XS_ACC's, when XS_ACC
        // would ask at once (no access of X or the engine out, the engine idle)
        if (x_hcommit && x_seq && !x_go && first_op(todo_n) == 4'(OP_ACC) && !x_stall &&
            !is_dm1(c.a[0].addr) && !is_pm(c.a[0].addr) && c.a[0].addr >= 32'h100 &&
            !xb_req && !eb_req && !e_busy && !e_start) begin
            xb_req <= 1'b1; xb_we <= !acc_is_rd(c.a[0].kind); xb_addr <= c.a[0].addr; xb_wdata <= c.a[0].wdata[31:0];
            xph <= XS_WAIT;
        end
        case (xph)
        XS_ACC: if (x_valid && !x_stall) begin
            acc_t a;
            a = x_acc[x_cur];
            if (x_ext_req) begin
                if (!xb_req && !eb_req && !e_busy) begin   // after the last DMA quantum, as MAME orders them
                    xb_req <= 1'b1; xb_we <= !acc_is_rd(a.kind); xb_addr <= a.addr; xb_wdata <= a.wdata[31:0];
                    xph <= XS_WAIT;
                end
            end else xph <= XS_WAIT;
        end
        XS_WAIT: if (x_valid) begin
            acc_t a;
            logic done;
            logic [47:0] d;
            a = x_acc[x_cur];
            done = 1'b1; d = 48'h0;
            if (is_pm(a.addr)) d = pm_q;
            else if (is_dm1(a.addr)) d = {16'h0, dm_qa};
            else if (a.addr < 32'h100) d = {16'h0, dbg_iop_ovr ? dbg_iop_val : (a.addr[7:0] == 8'h37) ? dma_status : 32'h0};
            else begin
                done = ext_ack;
                d = {16'h0, ext_rdata};
                if (ext_ack) xb_req <= 1'b0;
            end
            if (done) begin
                x_rdata[x_cur] <= (a.kind == A_PM_RD32 && is_pm(a.addr)) ? {16'h0, d[47:16]} : d;
                if (x_cur == 1'(x_n - 2'd1)) xph <= XS_POST;
                else begin x_cur <= x_cur + 1'b1; xph <= XS_ACC; end
            end
        end
        default: ;
        endcase

        if (x_fs_commit && c.irq_taken) irq_entry <= 1'b1;
        else if (x_exec_now) irq_entry <= 1'b0;
        if (x_go || x_squash) x_valid <= 1'b0;
        x_ef <= ld_go;
        if (x_ef) x_eld <= dm_qb;
        if (ld_go) x_ea <= el_a;
        if (d_go) begin
            x_valid <= 1'b1;
            xph <= XS_EXEC;
            x_pc <= d_pc;
            x_op <= pm_q;
            x_dec <= d_dec;
            x_ax <= fwd_e(d_dec.i_ax); x_ay <= fwd_e(d_dec.i_ay);
            x_mx <= fwd_e(d_dec.i_mx); x_my <= fwd_e(d_dec.i_my);
            x_e <= fwd_e(d_dec.i_e);
            x_s1 <= fwd_e(d_dec.i_s1); x_s2 <= fwd_e(d_dec.i_s2);
            x_fs[0] <= fwd_sel_e(d_dec.i_ax); x_fs[1] <= fwd_sel_e(d_dec.i_ay);
            x_fs[2] <= fwd_sel_e(d_dec.i_mx); x_fs[3] <= fwd_sel_e(d_dec.i_my);
            x_fs[4] <= fwd_sel_e(d_dec.i_e);
            x_fs[5] <= fwd_sel_e(d_dec.i_s1); x_fs[6] <= fwd_sel_e(d_dec.i_s2);
            x_fw0 <= xw_d0; x_fw1 <= xw_d1; x_fwu <= x_uw_d;
            for (int g = 0; g < 2; g++) begin
                x_dI[g] <= d_dI[g]; x_dM[g] <= d_dM[g];
                x_sM[g] <= d_dI[g] + d_dM[g]; x_sX[g] <= d_dI[g] + d_imm[g];
                x_pd[g] <= d_pd[g];
            end
            x_aok <= d_aok;
            x_late <= d_ci.late | (d_dec.ld & ~(ld_go ? bit16(el_r) : 16'h0));
            x_late_ld <= d_dec.ld & ~d_ci.late & ~(ld_go ? bit16(el_r) : 16'h0);
            x_dmw <= dm_write_form(pm_q); x_pb <= !SUBSET && pm_q[47:45] == 3'b001;
            x_el <= ld_go; x_el_r <= el_r;
        end

        // ---------------------------------------------------------------- F / D
        d_pc <= f_next;
        d_valid <= d_keep || d_go || (redirect && (x_squash || !d_valid || d_pc != redirect_pc)) ||
                   (!d_valid && !x_pm_read);
        if (x_pm_read || x_pm_write || e_pmw) d_valid <= 1'b0;
    end

    // IRQ lines (execute_set_input): after the X commit, as v1
    if (!reset) for (int k = 0; k < 3; k++)
        if (irq_assert[k]) Q.irq_pending[8 - k] <= 1'b1;
        else if (irq_in[k] != irq_prev[k]) Q.irq_pending[8 - k] <= irq_in[k];

    if (dbg_we) dbg_write(dbg_wsel, dbg_widx, dbg_wdata);
    if (boot_done) boot_apply();
end

// ------------------------------------------------------------------------------------------
// DMA engine
// ------------------------------------------------------------------------------------------

// a quantum starts after each instruction that leaves a channel active, and while idle; without
// DMA_LOCK, also whenever the last one is done
assign e_start = !e_busy && run && !booting &&
                 ((x_go && ((dma_status[7:6] != 0) || c.dma_exec)) ||
                  (Q.idle && dma_status[7:6] != 0 && !(x_valid && xph != XS_EXEC)) ||
                  (!DMA_LOCK && !serial && dma_status[7:6] != 0));

// without DMA_LOCK a TCB's words are read back to back: the next word's read goes out in the clock
// a word arrives
wire [31:0] e_tcb_a = e_addr(e_ch[0], e_step + 4'd1);
assign e_tcb_next = !DMA_LOCK && !serial && e_busy && e_wait && e_step >= 4'd2 && e_step < 4'd9 &&
                    is_dm1(e_tcb_a) && !x_portb;
// ... and a transfer's next source word from data memory is read in the clock its last word's
// external write is acknowledged, when no other channel is active and words remain
wire [31:0] e_nx_a = op_src[e_ch[0]] + op_src_mod[e_ch[0]];
assign e_rd_next = !DMA_LOCK && !serial && e_busy && e_wait && e_step == 4'd1 && eb_req && ext_ack &&
                   !op_tcb[e_ch[0]] && dma_reads(op_pmode[e_ch[0]]) == 3'd1 &&
                   $signed(op_src_count[e_ch[0]] - 32'd1) > 0 && !dma_status[{2'b11, !e_ch[0]}] &&
                   is_dm1(e_nx_a) && !x_portb;
// ... and a data-memory to Voodoo word's write is posted when the board will take it next clock
// (ext_post): the word ends as it is asked for, and the next is read at once
wire [31:0] e_pd = op_dst[e_ch[0]];
assign e_post_now = !DMA_LOCK && !serial && e_busy && e_wait && e_step == 4'd0 && is_dm1(e_addr(e_ch[0], 4'd0)) &&
                    e_pd >= 32'h0240_0000 && e_pd < 32'h0280_0000 && !op_tcb[e_ch[0]] &&
                    dma_reads(op_pmode[e_ch[0]]) == 3'd1 && ext_post && !xb_req;
assign e_post_rd = e_post_now && $signed(op_src_count[e_ch[0]] - 32'd1) > 0 && !dma_status[{2'b11, !e_ch[0]}] &&
                   is_dm1(e_nx_a) && !x_portb;

always_comb begin
    e_portb_do = 1'b0; e_portb_we = 1'b0; e_portb_a = 15'h0; e_portb_wd = 32'h0;
    e_do = 1'b0;
    if (e_tcb_next) begin
        e_portb_do = 1'b1;
        e_portb_a = 15'(e_tcb_a - 32'h28000);
    end
    if (e_rd_next || e_post_rd) begin
        e_portb_do = 1'b1;
        e_portb_a = 15'(e_nx_a - 32'h28000);
    end
    if (e_busy && !e_wait && e_sel != 2'd2) begin
        if (is_dm1(e_ad)) begin
            e_portb_do = !x_portb;
            e_do = !x_portb;
            e_portb_a = 15'(e_ad - 32'h28000);
            e_portb_we = e_stp == 4'd1;
            e_portb_wd = e_data;
        end else if (e_ad >= 32'h100 && !is_pm(e_ad)) e_do = !xb_req && !eb_post;
        else e_do = 1'b1;
    end
end

always_comb begin
    logic [31:0] ad;
    logic [2:0]  rds;
    logic        ch;
    e_irq_set = 32'h0;
    ch = e_ch[0];
    ad = e_addr(ch, e_step);
    rds = dma_reads(op_pmode[ch]);
    if (e_wr_now) begin ch = e_sel[0]; rds = dma_reads(op_pmode[ch]); end
    if (e_post_now) begin ch = e_ch[0]; rds = 3'd1; end
    if (ce && run && !booting &&
        ((e_busy && e_wait && e_step == 4'd1 &&
          (is_dm1(ad) || !(ad >= 32'h100 && !is_pm(ad)) || (ext_ack && eb_req))) || e_wr_now || e_post_now) &&
        $signed(op_src_count[ch] - {29'h0, rds}) <= 0 && (!op_chained[ch] || op_chain_ptr[ch][17]))
        e_irq_set[16 + ch] = 1'b1;
end

// a word's write is done: dma_advance, and the end of the transfer (or its chain's next TCB)
task automatic e_advance(input logic ch);
    logic [2:0] rds;
    rds = dma_reads(op_pmode[ch]);
    case (rds)
    3'd2:    op_src[ch] <= op_src[ch] + (op_src_mod[ch] << 1);
    3'd6:    op_src[ch] <= op_src[ch] + (op_src_mod[ch] << 2) + (op_src_mod[ch] << 1);
    default: op_src[ch] <= op_src[ch] + op_src_mod[ch];
    endcase
    op_dst[ch] <= op_dst[ch] + op_dst_mod[ch];
    op_src_count[ch] <= op_src_count[ch] - {29'h0, rds};
    e_k <= 3'd0;
    e_ch <= (!DMA_LOCK && !serial && ch) ? 2'd0 : {1'b0, ch} + 2'd1; e_step <= 4'd0;
    if ($signed(op_src_count[ch] - {29'h0, rds}) <= 0) begin
        dma_status[6 + ch] <= 1'b0;
        op_active[ch] <= 1'b0;
        if ((op_chain_ptr[ch] & 32'h1FFFF) != 0) begin
            op_tcb[ch] <= 1'b1;
            dma_status[6 + ch] <= 1'b1;
            e_ch <= {1'b0, ch}; e_step <= 4'd2;
        end
    end
endtask
// an internal (DM or PM) write needs no clock of its own: the word is done when it is issued
wire e_wr_now = e_busy && !e_wait && e_sel != 2'd2 && e_do && e_stp == 4'd1 && (is_dm1(e_ad) || is_pm(e_ad));

always_ff @(posedge clk) begin
    e_pmw <= 1'b0;
    if (reset) begin
        e_busy <= 1'b0; e_wait <= 1'b0; eb_req <= 1'b0; eb_post <= 1'b0;
    end else if (ce && run && !booting) begin
        if (eb_post && ext_ack) begin eb_req <= 1'b0; eb_post <= 1'b0; end
        if (x_go && c.dma_exec) begin
            // sharc_dma_exec (sharcdma.hxx:262-321)
            logic ch, chen, xmit, dtype;
            ch = c.dma_exec_ch;
            chen = c.s.dma_control[ch][1]; xmit = c.s.dma_control[ch][2]; dtype = c.s.dma_control[ch][5];
            if (chen) begin
                op_chain_ptr[ch] <= c.s.dma_chain_ptr[ch] & 32'h1FFFF;
                op_chain_dir[ch] <= {31'h0, xmit};
                op_active[ch] <= 1'b0;
                dma_status[6 + ch] <= 1'b1;
                op_tcb[ch] <= 1'b1;
            end else begin
                if (xmit) begin
                    op_dst[ch] <= c.s.dma_ext_index[ch]; op_dst_mod[ch] <= c.s.dma_ext_modifier[ch];
                    op_dst_count[ch] <= c.s.dma_ext_count[ch];
                    op_src[ch] <= (c.s.dma_int_index[ch] & 32'h1FFFF) | 32'h20000;
                    op_src_mod[ch] <= c.s.dma_int_modifier[ch]; op_src_count[ch] <= c.s.dma_int_count[ch];
                end else begin
                    op_src[ch] <= c.s.dma_ext_index[ch]; op_src_mod[ch] <= c.s.dma_ext_modifier[ch];
                    op_src_count[ch] <= c.s.dma_ext_count[ch];
                    op_dst[ch] <= (c.s.dma_int_index[ch] & 32'h1FFFF) | 32'h20000;
                    op_dst_mod[ch] <= c.s.dma_int_modifier[ch]; op_dst_count[ch] <= c.s.dma_int_count[ch];
                end
                op_pmode[ch] <= dtype ? 32'd4 : !DMA_PACK ? 32'h0 : {30'h0, c.s.dma_control[ch][7:6]};
// synthesis translate_off
                if (!DMA_PACK && !dtype && c.s.dma_control[ch][7:6] != 2'd0)
                    $display("sharc2_core: DMA channel %0d asks for packing (control %h); DMA_PACK is 0",
                             ch, c.s.dma_control[ch]);
// synthesis translate_on
                op_chain_ptr[ch] <= 32'h0;
                op_chained[ch] <= 1'b0;
                op_active[ch] <= 1'b1;
                dma_status[6 + ch] <= 1'b1;
            end
        end
        if (e_start) begin
            e_busy <= 1'b1; e_wait <= 1'b0;
            e_ch <= 2'd0; e_step <= 4'd0; e_k <= 3'd0;
        end else if (e_busy && !e_wait) begin
            if (e_sel == 2'd2) begin                          // no channel left
                // without DMA_LOCK the next quantum starts at once if a channel is still active
                if (!DMA_LOCK && !serial && dma_status[7:6] != 0) begin e_ch <= 2'd0; e_step <= 4'd0; e_k <= 3'd0; end
                else e_busy <= 1'b0;
            end else if (e_do) begin
                e_ch <= e_sel;
                e_step <= e_stp;
                if (!is_dm1(e_ad) && e_ad >= 32'h100 && !is_pm(e_ad)) begin
                    eb_req <= 1'b1; eb_we <= e_stp == 4'd1; eb_addr <= e_ad; eb_wdata <= e_data;
                end else if (is_pm(e_ad) && e_stp == 4'd1) begin
                    e_pmw <= 1'b1; e_pmw_a <= 15'(e_ad - 32'h20000); e_pmw_d <= e_pack;
                end
                if (e_wr_now) e_advance(e_sel[0]);
                else e_wait <= 1'b1;
            end
        end else if (e_busy && e_wait) begin
            logic [31:0] ad, d;
            logic done;
            logic ch;
            ch = e_ch[0];
            ad = e_addr(ch, e_step);
            done = 1'b1;
            if (is_dm1(ad)) d = dm_qb;
            else if (ad >= 32'h100 && !is_pm(ad)) begin
                done = ext_ack && eb_req; d = ext_rdata;
                if (done) eb_req <= 1'b0;
            end else d = 32'h0;
            if (done) begin
                e_wait <= 1'b0;
                if (e_step == 4'd0) begin
                    logic [31:0] pmo;
                    logic [47:0] w;
                    pmo = op_pmode[ch];
                    w = e_pack;
                    if (pmo == 32'd1) begin
                        if (e_k == 3'd0) w[31:16] = d[15:0]; else w[15:0] = d[15:0];
                    end else if (pmo == 32'd4) w[8 * e_k +: 8] = d[7:0];
                    else w = {16'h0, d};
                    e_pack <= w;
                    if (e_k + 3'd1 < dma_reads(pmo)) e_k <= e_k + 3'd1;
                    else begin
                        e_data <= w[31:0]; e_step <= 4'd1;
                        // without DMA_LOCK an external destination's write is asked for in the
                        // clock the word is read, not the clock after
                        if (!DMA_LOCK && !serial && !is_dm1(op_dst[ch]) && op_dst[ch] >= 32'h100 &&
                            !is_pm(op_dst[ch]) && !xb_req && !op_tcb[ch]) begin
                            eb_req <= 1'b1; eb_we <= 1'b1; eb_addr <= op_dst[ch]; eb_wdata <= w[31:0];
                            e_wait <= 1'b1;
                            // ... and a Voodoo write the board will take next clock is the word's end
                            if (e_post_now) begin
                                e_advance(ch);
                                eb_post <= 1'b1; e_wait <= 1'b0;
                                if (e_post_rd) begin e_ch <= {1'b0, ch}; e_step <= 4'd0; e_k <= 3'd0; e_wait <= 1'b1; end
                            end
                        end
                    end
                end else if (e_step == 4'd1) begin
                    e_advance(ch);
                    if (e_rd_next) begin e_ch <= {1'b0, ch}; e_step <= 4'd0; e_k <= 3'd0; e_wait <= 1'b1; end
                end
                else begin
                    tcb[e_step - 4'd2] <= d;
                    if (e_step == 4'd9) begin
                        logic [7:0][31:0] t;
                        t = tcb; t[7] = d;
                        // schedule_chained_dma_op (sharcdma.hxx:11-63)
                        if (op_chain_dir[ch][0]) begin
                            op_dst[ch] <= t[5]; op_dst_mod[ch] <= t[6]; op_dst_count[ch] <= t[7];
                            op_src[ch] <= t[0]; op_src_mod[ch] <= t[1]; op_src_count[ch] <= t[2];
                        end else begin
                            op_src[ch] <= t[5]; op_src_mod[ch] <= t[6]; op_src_count[ch] <= t[7];
                            op_dst[ch] <= t[0]; op_dst_mod[ch] <= t[1]; op_dst_count[ch] <= t[2];
                        end
                        op_pmode[ch] <= 32'h0;
                        op_tcb[ch] <= 1'b0;
                        op_chain_ptr[ch] <= t[3];
                        op_chained[ch] <= 1'b1;
                        op_active[ch] <= 1'b1;
                        dma_status[6 + ch] <= 1'b1;
                        e_ch <= (!DMA_LOCK && !serial) ? {1'b0, ch} : e_ch + 2'd1; e_step <= 4'd0;
                    end else begin
                        e_step <= e_step + 4'd1;
                        if (e_tcb_next) e_wait <= 1'b1;          // the next word's read is out
                    end
                end
            end
        end
    end
    if (dbg_we) dbg_write_dma(dbg_wsel, dbg_widx, dbg_wdata);
    if (boot_done) begin
        op_active[0] <= 1'b0;
        dma_status[6] <= 1'b0;
    end
end

// ------------------------------------------------------------------------------------------
// EPROM boot (v1 P_BOOT): RAMs cleared, then 0x600 bytes from 0x400000 packed into 0x100
// program words at 0x20000
// ------------------------------------------------------------------------------------------

always_comb begin
    boot_pm_we = 1'b0; boot_pm_wa = 15'h0; boot_pm_wd = 48'h0;
    boot_dm_we = 1'b0; boot_dm_wa = boot_n[14:0];
    if (booting && ce && boot_clear) begin
        boot_dm_we = 1'b1;
        if (boot_n < 16'h5000) begin boot_pm_we = 1'b1; boot_pm_wa = boot_n[14:0]; end
    end else if (booting && ce && bb_req && ext_ack && boot_k == 3'd5) begin
        logic [47:0] w;
        w = boot_w;
        w[8 * boot_k +: 8] = ext_rdata[7:0];
        boot_pm_we = 1'b1; boot_pm_wa = {7'h0, boot_pw}; boot_pm_wd = w;
    end
end
assign boot_done = booting && ce && !boot_clear && !bb_req && boot_n == 16'h600;

always_ff @(posedge clk) begin
    if (reset) begin
        booting <= 1'b0; bb_req <= 1'b0;
    end else if (boot) begin
        booting <= 1'b1;
        bb_req <= 1'b0;
        boot_clear <= 1'b1;
        boot_n <= 16'h0; boot_k <= 3'd0; boot_pw <= 8'd0;
    end else if (booting && ce) begin
        if (boot_clear) begin
            if (boot_n == 16'h7FFF) begin boot_clear <= 1'b0; boot_n <= 16'h0; end
            else boot_n <= boot_n + 16'd1;
        end else if (!bb_req) begin
            if (boot_n == 16'h600) booting <= 1'b0;
            else begin bb_req <= 1'b1; bb_addr <= 32'h400000 + {16'h0, boot_n}; end
        end else if (ext_ack) begin
            logic [47:0] w;
            bb_req <= 1'b0;
            w = boot_w;
            w[8 * boot_k +: 8] = ext_rdata[7:0];
            boot_w <= w;
            if (boot_k == 3'd5) begin boot_k <= 3'd0; boot_pw <= boot_pw + 8'd1; end
            else boot_k <= boot_k + 3'd1;
            boot_n <= boot_n + 16'd1;
        end
    end
end

// device_reset's state after the boot DMA (sharc.cpp:935-1000)
task automatic boot_apply();
    Q.dma_int_index[0] <= 32'h20000;  Q.dma_int_modifier[0] <= 32'd1; Q.dma_int_count[0] <= 32'h100;
    Q.dma_ext_index[0] <= 32'h400000; Q.dma_ext_modifier[0] <= 32'd1; Q.dma_ext_count[0] <= 32'h600;
    Q.dma_control[0] <= 32'h2A1;
    Q.pc <= 32'h20004; Q.daddr <= 32'h20005; Q.faddr <= 32'h20006; Q.nfaddr <= 32'h20007;
    Q.idle <= 1'b0;
    Q.mode1 <= 32'h0;
    Q.mode2 <= Q.mode2 & 32'hF000_0000;
    Q.astat <= Q.astat & FLGS;
    Q.stky <= PCEM | SSEM | LSEM;
    Q.irptl <= 32'h0;
    Q.imask <= 32'h3;
    Q.ustat1 <= 32'h0; Q.ustat2 <= 32'h0;
    Q.pcstkp <= 32'h0; Q.lstkp <= 32'h0;
    Q.pcstk <= 32'h00FF_FFFF;
    Q.curlcntr <= 32'hFFFF_FFFF;
    Q.lcntr <= lc_rd;                                  // lcstack[0] (lc_ra at boot_done)
    Q.laddr <= laddr_unpack(32'hFFFF_FFFF);
    Q.status_stkp <= 32'h0;
    Q.interrupt_active <= 1'b0;
    Q.syscon <= 32'h10;
    Q.sysstat <= Q.sysstat & 32'h0000_0FF0;
    Q.iop_delay_cycles <= 32'h0;
    run <= 1'b1;
    d_valid <= 1'b0; x_valid <= 1'b0; xph <= XS_EXEC; w_lwe <= 2'b00; xr_we <= 3'b000; swap_req <= '0; x_ef <= 1'b0; x_el <= 1'b0;
endtask

// ------------------------------------------------------------------------------------------
// Bench access
// ------------------------------------------------------------------------------------------

assign dbg_exec = ce && x_exec_now;
assign dbg_pc   = x_pc[23:0];
assign dbg_op   = x_op;
assign dbg_idle = Q.idle;

always_comb begin
    case (dbg_sel)
    6'd48: dbg_val = Q.astat;
    6'd49: dbg_val = Q.mode1;
    6'd50: dbg_val = Q.irptl;
    6'd51: dbg_val = Q.imask;
    6'd52: dbg_val = Q.pcstkp;
    6'd53: dbg_val = Q.lstkp;
    6'd54: dbg_val = Q.curlcntr;
    6'd55: dbg_val = Q.pcstk;
    default:
        if (dbg_sel < 6'd16)      dbg_val = xr_fwd(dbg_sel[3:0]);
        else if (dbg_sel < 6'd24) dbg_val = dgb_q[0];
        else if (dbg_sel < 6'd32) dbg_val = dgb_q[4] & 32'h00FF_FFFF;
        else if (dbg_sel < 6'd40) dbg_val = dgb_q[1];
        else                      dbg_val = dgb_q[5] & 32'h00FF_FFFF;
    endcase
end

task automatic dbg_write(input logic [7:0] sel, input logic [5:0] idx, input logic [63:0] d);
    case (sel)
    8'd0:  rfp[{rbk(idx[3:0]), idx[3:0]}] <= d[31:0];
    8'd1:  rfp[{!rbk(idx[3:0]), idx[3:0]}] <= d[31:0];
    8'd18: mrf <= d;
    8'd19: mrb <= d;
    8'd20: Q.px <= d[47:0];
    8'd21: Q.pc <= d[31:0];
    8'd22: Q.daddr <= d[31:0];
    8'd23: Q.faddr <= d[31:0];
    8'd24: Q.nfaddr <= d[31:0];
    8'd25: Q.delay_slot1 <= d[31:0];
    8'd26: Q.delay_slot2 <= d[31:0];
    8'd27: Q.pcstk <= d[31:0];
    8'd28: Q.pcstkp <= d[31:0];
    // 30, 31 (loop stacks), 36, 37 (status stack): their arrays' write ports
    8'd32: Q.curlcntr <= d[31:0];
    8'd33: Q.lcntr <= d[31:0];
    8'd34: Q.lstkp <= d[31:0];
    8'd35: Q.laddr <= laddr_unpack(d[31:0]);
    8'd38: Q.status_stkp <= d[31:0];
    8'd39: Q.astat <= d[31:0];
    8'd40: Q.astat_old <= d[31:0];
    8'd41: Q.astat_old_old <= d[31:0];
    8'd42: Q.astat_old_old_old <= d[31:0];
    8'd43: Q.mode1 <= d[31:0];
    8'd44: Q.mode2 <= d[31:0];
    8'd45: Q.stky <= d[31:0];
    8'd46: Q.irptl <= d[31:0];
    8'd47: Q.imask <= d[31:0];
    8'd48: Q.imaskp <= d[31:0];
    8'd49: Q.ustat1 <= d[31:0];
    8'd50: Q.ustat2 <= d[31:0];
    8'd51: Q.flag[idx[1:0]] <= d[0];
    8'd52: Q.syscon <= d[31:0];
    8'd53: Q.sysstat <= d[31:0];
    8'd54: Q.idle <= d[0];
    8'd55: Q.irq_pending <= d[31:0];
    8'd56: Q.active_irq_num <= d[31:0];
    8'd57: Q.interrupt_active <= d[0];
    8'd58: Q.lat_cycles <= d[31:0];
    8'd59: Q.lat_reg <= d[31:0];
    8'd60: Q.lat_data <= d[31:0];
    8'd61: Q.lat_prev <= d[31:0];
    8'd62: Q.dma_control[idx[0]] <= d[31:0];
    8'd63: Q.dma_int_index[idx[0]] <= d[31:0];
    8'd64: Q.dma_int_modifier[idx[0]] <= d[31:0];
    8'd65: Q.dma_int_count[idx[0]] <= d[31:0];
    8'd66: Q.dma_chain_ptr[idx[0]] <= d[31:0];
    8'd67: Q.dma_gen[idx[0]] <= d[31:0];
    8'd68: Q.dma_ext_index[idx[0]] <= d[31:0];
    8'd69: Q.dma_ext_modifier[idx[0]] <= d[31:0];
    8'd70: Q.dma_ext_count[idx[0]] <= d[31:0];
    8'd83: Q.iop_delay_cycles <= d[31:0];
    8'd84: Q.iop_delay_reg <= d[31:0];
    8'd85: Q.iop_delay_data <= d[31:0];
    8'd255: begin run <= 1'b1; d_valid <= 1'b0; x_valid <= 1'b0; xph <= XS_EXEC; end
    default: ;
    endcase
endtask

task automatic dbg_write_dma(input logic [7:0] sel, input logic [5:0] idx, input logic [63:0] d);
    case (sel)
    8'd71: op_active[idx[0]] <= d[0];
    8'd72: op_chained[idx[0]] <= d[0];
    8'd73: op_src[idx[0]] <= d[31:0];
    8'd74: op_dst[idx[0]] <= d[31:0];
    8'd75: op_src_mod[idx[0]] <= d[31:0];
    8'd76: op_dst_mod[idx[0]] <= d[31:0];
    8'd77: op_src_count[idx[0]] <= d[31:0];
    8'd78: op_dst_count[idx[0]] <= d[31:0];
    8'd79: op_pmode[idx[0]] <= d[31:0];
    8'd80: op_chain_ptr[idx[0]] <= d[31:0];
    8'd81: op_chain_dir[idx[0]] <= d[31:0];
    8'd82: dma_status <= d[31:0];
    8'd86: op_tcb[idx[0]] <= d[0];
    default: ;
    endcase
endtask

// synthesis translate_off
// benches: +dmalog prints each DMA start and the words each channel moves a quantum (board_tb)
always_ff @(posedge clk)
    if ($test$plusargs("dmalog") && ce && run && !booting && x_go && c.dma_exec)
        $display("SHARC DMA ch %0d: %s ext %08X mod %0d count %0d, int %05X mod %0d count %0d, ctl %08X", 6 + c.dma_exec_ch,
                 c.s.dma_control[c.dma_exec_ch][2] ? "to ext" : "from ext", c.s.dma_ext_index[c.dma_exec_ch],
                 $signed(c.s.dma_ext_modifier[c.dma_exec_ch]), c.s.dma_ext_count[c.dma_exec_ch],
                 c.s.dma_int_index[c.dma_exec_ch], $signed(c.s.dma_int_modifier[c.dma_exec_ch]),
                 c.s.dma_int_count[c.dma_exec_ch], c.s.dma_control[c.dma_exec_ch]);
// synthesis translate_on

endmodule
