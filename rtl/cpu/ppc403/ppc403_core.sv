// SPDX-License-Identifier: GPL-3.0-or-later
//
// IBM PowerPC 403GA integer core, written from MAME's model (src/devices/cpu/powerpc,
// ppccom.cpp and ppcdrc.cpp, PPCCAP_4XX). Big-endian, 31-bit physical address, no FPU,
// no MMU. MAME's semantics are followed where they differ from the IBM manual; each such
// place is marked "MAME:" and listed in docs/MAME_KLUDGES.md.
//
// Two stages. Fetch runs ahead of execute through a three-entry queue; execute works on the
// queue head (a register), reads the register file, computes and commits in one cycle, and
// holds the head while it is busy with a memory access, multiply, divide or a
// multiple/string/dcbz sequence. A taken branch, an exception or an interrupt redirects
// fetch and discards what is in flight.
//
// Ports: a request is issued in a cycle where req is high (and ce), and is answered by one
// ack no earlier than the next cycle, with the data valid in the ack cycle. One request per
// port is outstanding; the next may issue in the cycle of the ack. ce gates the whole core:
// a port must hold its ack until a ce cycle. Data lanes are big-endian: d_rdata[31:24] is
// the byte at (addr & ~3).
//
// On-chip peripherals outside the core (serial port, DMA) sit on the data bus and the DCR
// port. EXISR/EXIER/IOCR, the timers and the timebase are here because the exception
// logic reads them.

module ppc403_core (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,          // core step enable
    input  logic        tb_tick,     // timebase increment (the board's CPU clock, 32 MHz)

    output logic        i_req,
    output logic [30:0] i_addr,
    input  logic        i_ack,
    input  logic [31:0] i_rdata,

    output logic        d_req,
    output logic        d_we,
    output logic [30:0] d_addr,      // byte address
    output logic [3:0]  d_be,        // d_be[3] = byte 0 (bits 31:24)
    output logic [31:0] d_wdata,
    input  logic        d_ack,
    input  logic [31:0] d_rdata,

    // DCRs this core does not hold (bank registers, DMA, BEAR/BESR); dcr_rdata is read
    // combinationally from dcr_addr
    output logic        dcr_we,
    output logic        dcr_re,
    output logic [9:0]  dcr_addr,
    output logic [31:0] dcr_wdata,
    input  logic [31:0] dcr_rdata,

    input  logic [4:0]  ext_irq,     // IRQ0..4, high = asserted
    input  logic [8:0]  int_irq,     // level sources: [0] critical, [1] SPU rx, [2] SPU tx,
                                     // [3] JTAG rx, [4] JTAG tx, [8:5] DMA0-3

    // high in the cycle an instruction starts executing; the registers then hold the state
    // before it
    output logic        dbg_exec,
    output logic [31:0] dbg_pc,
    output logic [31:0] dbg_ir,
    input  logic [5:0]  dbg_sel,     // 0-31 GPR, 32 CR, 33 LR, 34 CTR, 35 XER, 36 MSR
    output logic [31:0] dbg_val,
    // state load (benches, savestates): the dbg_sel numbering, then 37 PC (fetch address),
    // 38 SRR0, 39 SRR1, 40-43 SPRG0-3, 44 EXIER, 45 EVPR, 46 TBL, 47 TBH, 48 TCR, 49 TSR (ORed
    // in), 50 EXISR, 51 IOCR, 52 PIT (value and reload), 53 PIT count (ticks to the next event,
    // 0 stopped), 54 external line state. Written whatever ce; PC only while nothing is in flight.
    input  logic        dbg_we,
    input  logic [5:0]  dbg_wsel,
    input  logic [31:0] dbg_wdata
);

// ---------------------------------------------------------------------------------------
// Architectural state
// ---------------------------------------------------------------------------------------

logic [31:0] gpr [32];
logic [31:0] cr, lr, ctr, msr;
logic [31:0] xer;            // SO in bit 31 as the architecture has it

logic [31:0] srr0, srr1, srr2, srr3;
logic [31:0] sprg [4];
logic [31:0] evpr, esr, dear, dear_oea;
logic [31:0] tcr, tsr, pit_spr;
logic [31:0] pbl1, pbu1, pbl2, pbu2;
logic [31:0] dccr, iccr, iac1, iac2, dac1, dac2, dbcr, dbsr, cdbcr;
logic [55:0] tb;
logic [31:0] exisr, exier, iocr;
logic        reserve;

logic [31:0] pit_reload;
logic [32:0] pit_count;      // ticks to the next PIT event; 0 = stopped
logic [4:0]  irqstate;       // previous external line state for edge detection

localparam logic [31:0] MSR_EE = 32'h0000_8000;
localparam logic [31:0] MSR_PR = 32'h0000_4000;
localparam logic [31:0] MSR_WE = 32'h0004_0000;
localparam logic [31:0] MSR_CE = 32'h0002_0000;
localparam logic [31:0] MSR_DE = 32'h0000_0200;
localparam logic [31:0] MSR_PE = 32'h0000_0008;

localparam logic [31:0] TCR_PIE = 32'h0400_0000;
localparam logic [31:0] TCR_FIE = 32'h0080_0000;
localparam logic [31:0] TCR_ARE = 32'h0040_0000;
localparam logic [31:0] TCR_WRC = 32'h3000_0000;
localparam logic [31:0] TSR_WIS = 32'h4000_0000;
localparam logic [31:0] TSR_PIS = 32'h0800_0000;
localparam logic [31:0] TSR_FIS = 32'h0400_0000;

// ---------------------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------------------

logic [31:0] fetch_pc;       // address of the next request
logic        f_out;          // a request is outstanding
logic        f_stale;        // ... and its instruction is to be dropped
logic [31:0] f_pc;           // address of the outstanding request
logic [1:0]  q_n;            // instruction queue, head in [0]
logic [31:0] q_ir [3];
logic [31:0] q_pc [3];

wire         f_ack_ok  = i_ack && f_out && !f_stale;
wire         xin_valid = q_n != 2'd0;
wire [31:0]  xin_ir    = q_ir[0];
wire [31:0]  xin_pc    = q_pc[0];

// ---------------------------------------------------------------------------------------
// Execute state
// ---------------------------------------------------------------------------------------

typedef enum logic [2:0] {
    X_IDLE, X_MEM, X_MUL, X_MUL2, X_DIV, X_MULTI, X_MULTI_WAIT, X_DONE
} xstate_t;
xstate_t xstate;


typedef enum logic [2:0] {
    M_LOAD, M_STORE, M_LMW, M_STMW, M_LSW, M_STSW, M_DCBZ
} mop_t;
mop_t        mop;
logic [1:0]  msize;          // 0 byte, 1 half, 2 word
logic        msign, mrev, mupd, mresv;
logic [31:0] mea;            // effective address
logic [4:0]  mreg;           // current register of a multiple
logic [6:0]  mcount;         // bytes / words left
logic [1:0]  mbyte;          // byte within the register (string ops)

logic [31:0] div_q, div_r, div_d;
logic [5:0]  div_n;
logic        div_neg_q;

// pending external interrupt, as MAME computes irq_pending (ppccom.cpp:2573-2577)
wire irq_pending = ((exisr & exier) != 0) ||
                   ((tcr & TCR_FIE) != 0 && (tsr & TSR_FIS) != 0) ||
                   ((tcr & TCR_PIE) != 0 && (tsr & TSR_PIS) != 0);

// EXISR level mask from IOCR (ppccom.cpp:2556-2563)
wire [31:0] level_mask = 32'h8F00_0000 | 32'h00F0_0000 |
                         {27'h0, ~iocr[31], ~iocr[29], ~iocr[27], ~iocr[25], ~iocr[23]};
wire [31:0] line_bits  = {int_irq[0], 3'b000, int_irq[2:1], int_irq[4:3], int_irq[8:5],
                          15'h0, ext_irq[0], ext_irq[1], ext_irq[2], ext_irq[3], ext_irq[4]};

// multiplier: operands registered at the start, product one clock later (DSP blocks)
logic [32:0] mul_a, mul_b;
logic [65:0] mul_p;
always_ff @(posedge clk) if (ce) mul_p <= $signed(mul_a) * $signed(mul_b);

wire x_ready  = (xstate == X_IDLE);
// MAME gates every interrupt on MSR[EE] (ppcdrc.cpp:805-811)
wire irq_take = x_ready && xin_valid && irq_pending && msr[15];
wire x_start  = x_ready && xin_valid && !irq_take;

// ---------------------------------------------------------------------------------------
// Instruction fields: the instruction starting, or the one a busy state holds
// ---------------------------------------------------------------------------------------

wire [31:0] ir    = xin_ir;
wire [31:0] pc    = xin_pc;
wire [5:0]  op    = ir[31:26];
wire [4:0]  rd    = ir[25:21];
wire [4:0]  ra    = ir[20:16];
wire [4:0]  rb    = ir[15:11];
wire [9:0]  xo    = ir[10:1];
wire [8:0]  xo9   = ir[9:1];
wire        oe    = ir[10];
wire        rc    = ir[0];
wire [15:0] imm   = ir[15:0];
wire [31:0] simm  = {{16{ir[15]}}, ir[15:0]};
wire [31:0] uimm  = {16'h0, ir[15:0]};
wire [4:0]  sh    = ir[15:11];
wire [4:0]  mb    = ir[10:6];
wire [4:0]  me    = ir[5:1];
wire [2:0]  crfd  = ir[25:23];
wire [2:0]  crfs  = ir[20:18];
wire [9:0]  sprn  = {ir[15:11], ir[20:16]};

wire [31:0] va    = gpr[ra];
wire [31:0] va0   = (ra == 5'd0) ? 32'h0 : va;
wire [31:0] vb    = gpr[rb];
wire [31:0] vs    = gpr[rd];

wire        so    = xer[31];
wire        ca    = xer[29];

function automatic logic [31:0] rotl(input logic [31:0] v, input logic [4:0] n);
    rotl = (v << n) | (v >> (6'd32 - {1'b0, n}));
endfunction

function automatic logic [31:0] mask(input logic [4:0] b, input logic [4:0] e);
    logic [31:0] m1, m2;
    m1 = 32'hFFFF_FFFF >> b;
    m2 = ~(32'hFFFF_FFFF >> e >> 1);
    mask = (b <= e) ? (m1 & m2) : (m1 | m2);
endfunction

function automatic logic [3:0] cmp_s(input logic [31:0] a, input logic [31:0] b, input logic s);
    cmp_s = {$signed(a) < $signed(b), $signed(a) > $signed(b), a == b, s};
endfunction

function automatic logic [3:0] cmp_u(input logic [31:0] a, input logic [31:0] b, input logic s);
    cmp_u = {a < b, a > b, a == b, s};
endfunction

function automatic logic [5:0] clz(input logic [31:0] v);
    clz = 6'd32;
    for (int i = 0; i < 32; i++)
        if (v[i]) clz = 6'(31 - i);
endfunction

function automatic logic [31:0] lane_rd(input logic [31:0] w, input logic [1:0] a,
                                        input logic [1:0] sz);
    case (sz)
    2'd0:    lane_rd = {24'h0, w[31 - 8*a -: 8]};
    2'd1:    lane_rd = a[1] ? {16'h0, w[15:0]} : {16'h0, w[31:16]};
    default: lane_rd = w;
    endcase
endfunction

function automatic logic [3:0] lane_be(input logic [1:0] a, input logic [1:0] sz);
    case (sz)
    2'd0:    lane_be = 4'b1000 >> a;
    2'd1:    lane_be = a[1] ? 4'b0011 : 4'b1100;
    default: lane_be = 4'b1111;
    endcase
endfunction

function automatic logic [31:0] lane_wr(input logic [31:0] v, input logic [1:0] sz);
    case (sz)
    2'd0:    lane_wr = {4{v[7:0]}};
    2'd1:    lane_wr = {2{v[15:0]}};
    default: lane_wr = v;
    endcase
endfunction

function automatic logic [31:0] bswap(input logic [31:0] v, input logic [1:0] sz);
    bswap = (sz == 2'd1) ? {16'h0, v[7:0], v[15:8]} : {v[7:0], v[15:8], v[23:16], v[31:24]};
endfunction

// 4xx write protection (ppccom.cpp:1336-1344): 1 = the write faults
function automatic logic prot_fault(input logic [31:0] a);
    logic in1, in2;
    in1 = (a[31:12] >= pbl1[31:12]) && (a[31:12] < pbu1[31:12]);
    in2 = (a[31:12] >= pbl2[31:12]) && (a[31:12] < pbu2[31:12]);
    prot_fault = msr[3] && (msr[2] ? (in1 || in2) : (!in1 && !in2));
endfunction

function automatic logic [3:0] cr0_of(input logic [31:0] r, input logic s);
    cr0_of = {r[31], !r[31] && r != 0, r == 0, s};
endfunction

function automatic logic trap(input logic [4:0] to, input logic [31:0] a, input logic [31:0] b);
    trap = (to[4] && $signed(a) < $signed(b)) || (to[3] && $signed(a) > $signed(b)) ||
           (to[2] && a == b) || (to[1] && a < b) || (to[0] && a > b);
endfunction

// ---------------------------------------------------------------------------------------
// Adder shared by the add/subtract family
// ---------------------------------------------------------------------------------------

logic [31:0] add_a, add_b;
logic        add_cin;
logic [32:0] add_sum;
wire         add_ov = (add_a[31] == add_b[31]) && (add_sum[31] != add_a[31]);
assign add_sum = {1'b0, add_a} + {1'b0, add_b} + {32'h0, add_cin};

always_comb begin
    add_a = va; add_b = vb; add_cin = 1'b0;
    if (op == 6'd31) begin
        case (xo9)
        9'd8:   begin add_a = ~va; add_b = vb;            add_cin = 1'b1; end // subfc
        9'd10:  begin add_a = va;  add_b = vb;            add_cin = 1'b0; end // addc
        9'd40:  begin add_a = ~va; add_b = vb;            add_cin = 1'b1; end // subf
        9'd104: begin add_a = ~va; add_b = 32'h0;         add_cin = 1'b1; end // neg
        9'd136: begin add_a = ~va; add_b = vb;            add_cin = ca;   end // subfe
        9'd138: begin add_a = va;  add_b = vb;            add_cin = ca;   end // adde
        9'd200: begin add_a = ~va; add_b = 32'h0;         add_cin = ca;   end // subfze
        9'd202: begin add_a = va;  add_b = 32'h0;         add_cin = ca;   end // addze
        9'd232: begin add_a = ~va; add_b = 32'hFFFF_FFFF; add_cin = ca;   end // subfme
        9'd234: begin add_a = va;  add_b = 32'hFFFF_FFFF; add_cin = ca;   end // addme
        default: begin add_a = va; add_b = vb;            add_cin = 1'b0; end // add
        endcase
    end else begin
        case (op)
        6'd8:    begin add_a = ~va; add_b = simm; add_cin = 1'b1; end         // subfic
        6'd12,
        6'd13:   begin add_a = va;  add_b = simm; add_cin = 1'b0; end         // addic, addic.
        6'd14:   begin add_a = va0; add_b = simm; add_cin = 1'b0; end         // addi
        default: begin add_a = va0; add_b = {imm, 16'h0}; add_cin = 1'b0; end // addis
        endcase
    end
end

// ---------------------------------------------------------------------------------------
// The one-cycle integer group
// ---------------------------------------------------------------------------------------

logic        x_wr;           // write gpr[x_dst]
logic [4:0]  x_dst;
logic [31:0] x_val;
logic        x_rc;           // set CR0 from x_val
logic        x_ca_we, x_ca;
logic        x_ov_we, x_ov;

always_comb begin
    x_wr = 1'b0; x_dst = rd; x_val = 32'h0; x_rc = 1'b0;
    x_ca_we = 1'b0; x_ca = 1'b0; x_ov_we = 1'b0; x_ov = 1'b0;
    case (op)
    6'd8:  begin x_wr = 1; x_val = add_sum[31:0]; x_ca_we = 1; x_ca = add_sum[32]; end  // subfic
    6'd12: begin x_wr = 1; x_val = add_sum[31:0]; x_ca_we = 1; x_ca = add_sum[32]; end  // addic
    6'd13: begin x_wr = 1; x_val = add_sum[31:0]; x_ca_we = 1; x_ca = add_sum[32]; x_rc = 1; end
    6'd14, 6'd15: begin x_wr = 1; x_val = add_sum[31:0]; end                            // addi, addis
    6'd20: begin x_wr = 1; x_dst = ra; x_rc = rc;                                        // rlwimi
                 x_val = (rotl(vs, sh) & mask(mb, me)) | (va & ~mask(mb, me)); end
    6'd21: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = rotl(vs, sh) & mask(mb, me); end
    6'd23: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = rotl(vs, vb[4:0]) & mask(mb, me); end
    6'd24: begin x_wr = 1; x_dst = ra; x_val = vs | uimm; end
    6'd25: begin x_wr = 1; x_dst = ra; x_val = vs | {imm, 16'h0}; end
    6'd26: begin x_wr = 1; x_dst = ra; x_val = vs ^ uimm; end
    6'd27: begin x_wr = 1; x_dst = ra; x_val = vs ^ {imm, 16'h0}; end
    6'd28: begin x_wr = 1; x_dst = ra; x_val = vs & uimm; x_rc = 1; end
    6'd29: begin x_wr = 1; x_dst = ra; x_val = vs & {imm, 16'h0}; x_rc = 1; end
    6'd31: begin
        case (xo9)
        9'd8, 9'd10, 9'd136, 9'd138, 9'd200, 9'd202, 9'd232, 9'd234: begin
            x_wr = 1; x_val = add_sum[31:0]; x_rc = rc; x_ca_we = 1; x_ca = add_sum[32];
            x_ov_we = oe; x_ov = add_ov;
        end
        9'd40, 9'd266: begin
            x_wr = 1; x_val = add_sum[31:0]; x_rc = rc; x_ov_we = oe; x_ov = add_ov;
        end
        9'd104: begin
            x_wr = 1; x_val = add_sum[31:0]; x_rc = rc; x_ov_we = oe; x_ov = (va == 32'h8000_0000);
        end
        default: ;
        endcase
        case (xo)
        10'd24:  begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vb[5] ? 32'h0 : vs << vb[4:0]; end
        10'd536: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vb[5] ? 32'h0 : vs >> vb[4:0]; end
        10'd26:  begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = {26'h0, clz(vs)}; end
        10'd28:  begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vs & vb; end
        10'd60:  begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vs & ~vb; end
        10'd124: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = ~(vs | vb); end
        10'd284: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = ~(vs ^ vb); end
        10'd316: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vs ^ vb; end
        10'd412: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vs | ~vb; end
        10'd444: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = vs | vb; end
        10'd476: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = ~(vs & vb); end
        10'd922: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = {{16{vs[15]}}, vs[15:0]}; end
        10'd954: begin x_wr = 1; x_dst = ra; x_rc = rc; x_val = {{24{vs[7]}}, vs[7:0]}; end
        10'd792: begin                                                         // sraw
            x_wr = 1; x_dst = ra; x_rc = rc; x_ca_we = 1;
            if (vb[5]) begin
                x_val = {32{vs[31]}}; x_ca = vs[31] && vs != 0;
            end else begin
                x_val = 32'($signed(vs) >>> vb[4:0]);
                x_ca  = vs[31] && ((vs & ~(32'hFFFF_FFFF << vb[4:0])) != 0);
            end
        end
        10'd824: begin                                                         // srawi
            x_wr = 1; x_dst = ra; x_rc = rc; x_ca_we = 1;
            x_val = 32'($signed(vs) >>> sh);
            x_ca  = vs[31] && ((vs & ~(32'hFFFF_FFFF << sh)) != 0);
        end
        default: ;
        endcase
    end
    default: ;
    endcase
end

// ---------------------------------------------------------------------------------------
// SPR and DCR reads
// ---------------------------------------------------------------------------------------

logic [31:0] mfspr_val;
always_comb begin
    case (sprn)
    10'h001: mfspr_val = xer;
    10'h008: mfspr_val = lr;
    10'h009: mfspr_val = ctr;
    10'h000: mfspr_val = 32'h0;                          // MAME: MQ reads 0 (ppcdrc.cpp:4248)
    10'h013: mfspr_val = dear_oea;                       // MAME: alignment writes the OEA DAR
    10'h01a: mfspr_val = srr0;
    10'h01b: mfspr_val = srr1;
    10'h110: mfspr_val = sprg[0];
    10'h111: mfspr_val = sprg[1];
    10'h112: mfspr_val = sprg[2];
    10'h113: mfspr_val = sprg[3];
    10'h11f: mfspr_val = 32'h0020_0000;                  // MAME: PVR = PPC_MODEL_403GA (ppc.h:193)
    10'h3d4: mfspr_val = esr;
    10'h3d5: mfspr_val = dear;
    10'h3d6: mfspr_val = evpr;
    10'h3d7: mfspr_val = cdbcr;
    10'h3d8: mfspr_val = tsr;
    10'h3da: mfspr_val = tcr;
    10'h3db: mfspr_val = pit_spr;                        // MAME: the written value, not a count
    10'h3dc, 10'h3cc: mfspr_val = {8'h0, tb[55:32]};
    10'h3dd, 10'h3cd: mfspr_val = tb[31:0];
    10'h3de: mfspr_val = srr2;
    10'h3df: mfspr_val = srr3;
    10'h3f0: mfspr_val = dbsr;
    10'h3f2: mfspr_val = dbcr;
    10'h3f4: mfspr_val = iac1;
    10'h3f5: mfspr_val = iac2;
    10'h3f6: mfspr_val = dac1;
    10'h3f7: mfspr_val = dac2;
    10'h3fa: mfspr_val = dccr;
    10'h3fb: mfspr_val = iccr;
    10'h3fc: mfspr_val = pbl1;
    10'h3fd: mfspr_val = pbu1;
    10'h3fe: mfspr_val = pbl2;
    10'h3ff: mfspr_val = pbu2;
    default: mfspr_val = 32'h0;
    endcase
end

wire dcr_local = (sprn == 10'h040) || (sprn == 10'h042) || (sprn == 10'h0a0);
wire [31:0] mfdcr_val = (sprn == 10'h040) ? exisr : (sprn == 10'h042) ? exier :
                        (sprn == 10'h0a0) ? iocr : dcr_rdata;

// ---------------------------------------------------------------------------------------
// Decode of the starting instruction: class, effective address, exceptions
// ---------------------------------------------------------------------------------------

// D-form and X-form loads/stores
logic        ls_is, ls_st, ls_up, ls_sign, ls_rev, ls_resv;
logic [1:0]  ls_sz;
logic [31:0] ls_ea;
always_comb begin
    ls_is = 1'b0; ls_st = 1'b0; ls_up = 1'b0; ls_sign = 1'b0; ls_rev = 1'b0; ls_resv = 1'b0;
    ls_sz = 2'd2;
    ls_ea = va0 + simm;
    case (op)
    6'd32, 6'd33, 6'd34, 6'd35, 6'd40, 6'd41, 6'd42, 6'd43,
    6'd36, 6'd37, 6'd38, 6'd39, 6'd44, 6'd45: begin
        ls_is = 1'b1;
        ls_ea = (op[0] ? va : va0) + simm;
        ls_st = (op >= 6'd36 && op <= 6'd39) || op == 6'd44 || op == 6'd45;
        ls_up = op[0];
        ls_sign = (op == 6'd42 || op == 6'd43);
        case (op)
        6'd34, 6'd35, 6'd38, 6'd39: ls_sz = 2'd0;
        6'd40, 6'd41, 6'd42, 6'd43, 6'd44, 6'd45: ls_sz = 2'd1;
        default: ls_sz = 2'd2;
        endcase
    end
    6'd31: begin
        ls_ea = va0 + vb;
        case (xo)
        10'd23, 10'd55, 10'd87, 10'd119, 10'd279, 10'd311, 10'd343, 10'd375,
        10'd151, 10'd183, 10'd215, 10'd247, 10'd407, 10'd439,
        10'd534, 10'd662, 10'd790, 10'd918, 10'd20, 10'd150: begin
            ls_is = 1'b1;
            ls_up = (xo == 10'd55 || xo == 10'd119 || xo == 10'd311 || xo == 10'd375 ||
                     xo == 10'd183 || xo == 10'd247 || xo == 10'd439);
            ls_st = (xo == 10'd151 || xo == 10'd183 || xo == 10'd215 || xo == 10'd247 ||
                     xo == 10'd407 || xo == 10'd439 || xo == 10'd662 || xo == 10'd918 ||
                     xo == 10'd150);
            ls_sign = (xo == 10'd343 || xo == 10'd375);
            ls_rev  = (xo == 10'd534 || xo == 10'd662 || xo == 10'd790 || xo == 10'd918);
            ls_resv = (xo == 10'd20 || xo == 10'd150);
            case (xo)
            10'd87, 10'd119, 10'd215, 10'd247: ls_sz = 2'd0;
            10'd279, 10'd311, 10'd343, 10'd375, 10'd407, 10'd439, 10'd790, 10'd918: ls_sz = 2'd1;
            default: ls_sz = 2'd2;
            endcase
        end
        default: ;
        endcase
    end
    default: ;
    endcase
end

wire ls_misal = (ls_sz == 2'd1 && ls_ea[0]) || (ls_sz == 2'd2 && ls_ea[1:0] != 0);
wire ls_prot  = ls_st && prot_fault(ls_ea);
wire ls_skip  = ls_resv && ls_st && !reserve;          // stwcx. without a reservation
wire ls_go    = x_start && ls_is && !ls_misal && !ls_prot && !ls_skip;

// the multiple/string/dcbz sequences issue from registers
logic [31:0] mseq_wdata;
logic [3:0]  mseq_be;
always_comb begin
    case (mop)
    M_LSW, M_STSW: begin mseq_be = 4'b1000 >> mea[1:0]; mseq_wdata = {4{gpr[mreg][31 - 8*mbyte -: 8]}}; end
    M_DCBZ:        begin mseq_be = 4'b1111; mseq_wdata = 32'h0; end
    default:       begin mseq_be = 4'b1111; mseq_wdata = gpr[mreg]; end
    endcase
end

always_comb begin
    if (xstate == X_MULTI) begin
        d_req   = 1'b1;
        d_we    = (mop == M_STMW || mop == M_STSW || mop == M_DCBZ);
        d_addr  = mea[30:0];
        d_be    = mseq_be;
        d_wdata = mseq_wdata;
    end else begin
        d_req   = ls_go;
        d_we    = ls_st;
        d_addr  = ls_ea[30:0];
        d_be    = lane_be(ls_ea[1:0], ls_sz);
        d_wdata = lane_wr(ls_rev ? bswap(vs, ls_sz) : vs, ls_sz);
    end
end

// Whether the head leaves the queue this cycle, from the opcode class and the busy state
// alone (not from the address checks: an exception flushes the queue anyway). The
// sequential `pop` below computes the same thing the long way; simulation checks they agree.
wire start_busy = op == 6'd7 || op == 6'd46 || op == 6'd47 || ls_is ||
                  (op == 6'd31 && (xo == 10'd11 || xo == 10'd75 || xo == 10'd235 || xo == 10'd747 ||
                                   xo == 10'd459 || xo == 10'd971 || xo == 10'd491 || xo == 10'd1003 ||
                                   xo == 10'd597 || xo == 10'd533 || xo == 10'd725 || xo == 10'd661 ||
                                   xo == 10'd1014));
wire busy_fin = (xstate == X_MEM && d_ack) || xstate == X_MUL2 || (xstate == X_DIV && div_n == 0) ||
                xstate == X_DONE ||
                (xstate == X_MULTI_WAIT && d_ack &&
                 ((mop == M_LMW || mop == M_STMW) ? mreg == 5'd31 : mcount == 7'd1));
wire q_pop = irq_take || (x_start && !start_busy) || busy_fin;

// ---------------------------------------------------------------------------------------
// Fetch requests
// ---------------------------------------------------------------------------------------

// the instruction arriving now goes to the buffer unless execute takes it
// issue only if the queue has room for this request even when nothing is popped meanwhile
assign i_req  = (!f_out || i_ack) && ({1'b0, q_n} + {2'b0, f_ack_ok} <= 3'd2);
assign i_addr = fetch_pc[30:0];

// ---------------------------------------------------------------------------------------
// Debug
// ---------------------------------------------------------------------------------------

always_comb begin
    case (dbg_sel)
    6'd32:   dbg_val = cr;
    6'd33:   dbg_val = lr;
    6'd34:   dbg_val = ctr;
    6'd35:   dbg_val = xer;
    6'd36:   dbg_val = msr;
    default: dbg_val = gpr[dbg_sel[4:0]];
    endcase
end

assign dbg_exec  = x_start;
assign dbg_pc    = xin_pc;
assign dbg_ir    = xin_ir;
assign dcr_addr  = sprn;
assign dcr_wdata = vs;
assign dcr_we    = x_start && op == 6'd31 && xo == 10'd451 && !dcr_local;
assign dcr_re    = x_start && op == 6'd31 && xo == 10'd323 && !dcr_local;

// branch condition (BO numbered from the MSB: ir[25] = BO0)
wire [31:0] ctr_dec = ctr - 32'd1;
wire        bi_bit  = cr[31 - ir[20:16]];
wire        br_ctr  = ir[23] || ((ctr_dec != 0) ^ ir[22]);
wire        br_cond = ir[25] || (bi_bit == ir[24]);

wire [31:0] fit_mask = (32'h200 << {tcr[25:24], 2'b00}) - 32'd1;

// ---------------------------------------------------------------------------------------
// Sequential
// ---------------------------------------------------------------------------------------

task automatic set_cr_field(input logic [2:0] f, input logic [3:0] v);
    cr[31 - 4*f -: 4] <= v;
endtask

// the two register-file write ports
logic        w1_en, w2_en;
logic [4:0]  w1_idx, w2_idx;
logic [31:0] w1_val, w2_val;

always_ff @(posedge clk) begin
    // external interrupt lines: edge-set, level-mirror (ppccom.cpp:2539-2572)
    irqstate <= ext_irq;
    begin
        logic [31:0] rise, nx;
        rise = {27'h0, ext_irq[0] & ~irqstate[0], ext_irq[1] & ~irqstate[1],
                ext_irq[2] & ~irqstate[2], ext_irq[3] & ~irqstate[3], ext_irq[4] & ~irqstate[4]};
        nx = exisr | rise;
        exisr <= (nx & ~level_mask) | (line_bits & level_mask);
    end

    // timebase, PIT and FIT at the board clock
    if (tb_tick) begin
        tb <= tb + 56'd1;
        if (pit_count != 0) begin
            if (pit_count == 33'd1) begin
                tsr <= tsr | TSR_PIS;
                pit_count <= ((tcr & TCR_ARE) != 0 && (tcr & TCR_PIE) != 0)
                             ? {1'b0, pit_reload} + 33'd1 : 33'd0;
            end else
                pit_count <= pit_count - 33'd1;
        end
        // MAME fires one tick after the timebase crosses a multiple of the period
        if ((tcr & TCR_FIE) != 0 && ((tb[31:0] & fit_mask) == 32'h0))
            tsr <= tsr | TSR_FIS;
    end

    w1_en = 1'b0; w1_idx = rd; w1_val = 32'h0;
    w2_en = 1'b0; w2_idx = ra; w2_val = 32'h0;

    if (reset) begin
        xstate   <= X_IDLE;
        fetch_pc <= 32'hFFFF_FFFC;
        f_out    <= 1'b0;
        f_stale  <= 1'b0;
        q_n      <= 2'd0;
        msr      <= 32'h0;
        tcr      <= 32'h0;               // MAME clears only WRC; the rest is power-on zero
        tsr      <= 32'h0;
        exisr    <= 32'h0;
        exier    <= 32'h0;
        iocr     <= 32'h0;
        tb       <= 56'h0;
        pit_count <= 33'd0;
        reserve  <= 1'b0;
        irqstate <= 5'h0;
        cr <= 32'h0; lr <= 32'h0; ctr <= 32'h0; xer <= 32'h0;
        for (int i = 0; i < 32; i++) gpr[i] <= 32'h0;
    end else if (ce) begin
        logic        redirect;
        logic [31:0] target;
        logic        pop;            // the head instruction is finished
        redirect = 1'b0; target = 32'h0; pop = 1'b0;

        // ---------------------------------------------------------------- interrupt
        if (irq_take) begin
            // external / timer interrupt (ppcdrc.cpp:1069-1100)
            logic [11:0] v;
            v = 12'h500;
            pop = 1'b1;
            if ((tsr & TSR_PIS) != 0) v = 12'h000;          // 0x1000
            if ((tsr & TSR_FIS) != 0) v = 12'h010;          // 0x1010
            if ((exisr & exier) != 0) v = 12'h500;
            redirect = 1'b1;
            if ((tsr & TSR_WIS) != 0) begin
                srr2 <= xin_pc; srr3 <= msr;
                msr  <= (msr & ~(MSR_WE | MSR_PR | MSR_CE | MSR_EE | MSR_DE | MSR_PE))
                        & ~32'h1 | {31'h0, msr[16]};
                target = {evpr[31:16], 16'h1020};
            end else begin
                srr0 <= xin_pc; srr1 <= msr;
                msr  <= (msr & ~(MSR_WE | MSR_PR | MSR_EE | MSR_PE)) & ~32'h1 | {31'h0, msr[16]};
                target = {evpr[31:16], (v == 12'h500) ? 16'h0500 : {4'h1, v}};
            end
        end

        // ---------------------------------------------------------------- start
        if (x_start) begin
            logic        take_exc;
            logic [11:0] ev;
            logic [31:0] ev_srr0, ev_esr;
            pop = 1'b1;
            take_exc = 1'b0; ev = 12'h700; ev_srr0 = pc; ev_esr = 32'h0;

            if (x_wr) begin w1_en = 1'b1; w1_idx = x_dst; w1_val = x_val; end
            if (x_ca_we) xer[29] <= x_ca;
            if (x_ov_we) begin xer[30] <= x_ov; if (x_ov) xer[31] <= 1'b1; end
            if (x_rc) set_cr_field(3'd0, cr0_of(x_val, (x_ov_we && x_ov) || so));

            case (op)
            6'd3: if (trap(rd, va, simm)) begin take_exc = 1; ev_esr = 32'h0200_0000; end   // twi
            6'd7: begin                                                           // mulli
                mul_a <= {va[31], va}; mul_b <= {simm[31], simm};
                xstate <= X_MUL; pop = 1'b0;
            end
            6'd10: set_cr_field(crfd, cmp_u(va, uimm, so));
            6'd11: set_cr_field(crfd, cmp_s(va, simm, so));
            6'd16: begin                                                          // bc
                if (!ir[23]) ctr <= ctr_dec;
                if (br_ctr && br_cond) begin
                    redirect = 1'b1;
                    target = (ir[1] ? 32'h0 : pc) + {{16{ir[15]}}, ir[15:2], 2'b00};
                end
                if (ir[0]) lr <= pc + 32'd4;
            end
            6'd17: begin take_exc = 1; ev = 12'hC00; ev_srr0 = pc + 32'd4; end    // sc
            6'd18: begin                                                          // b
                redirect = 1'b1;
                target = (ir[1] ? 32'h0 : pc) + {{6{ir[25]}}, ir[25:2], 2'b00};
                if (ir[0]) lr <= pc + 32'd4;
            end
            6'd19: begin
                case (xo)
                10'd0: set_cr_field(crfd, cr[31 - 4*crfs -: 4]);                    // mcrf
                10'd16: begin                                                     // bclr
                    if (!ir[23]) ctr <= ctr_dec;
                    if (br_ctr && br_cond) begin redirect = 1'b1; target = {lr[31:2], 2'b00}; end
                    if (ir[0]) lr <= pc + 32'd4;
                end
                10'd528: begin                                                    // bcctr
                    if (br_cond) begin redirect = 1'b1; target = {ctr[31:2], 2'b00}; end
                    if (ir[0]) lr <= pc + 32'd4;
                end
                10'd33, 10'd129, 10'd193, 10'd225, 10'd257, 10'd289, 10'd417, 10'd449: begin
                    logic a, b, r;
                    a = cr[31 - ir[20:16]]; b = cr[31 - ir[15:11]];
                    case (xo)
                    10'd33:  r = ~(a | b);
                    10'd129: r = a & ~b;
                    10'd193: r = a ^ b;
                    10'd225: r = ~(a & b);
                    10'd257: r = a & b;
                    10'd289: r = ~(a ^ b);
                    10'd417: r = a | ~b;
                    default: r = a | b;
                    endcase
                    cr[31 - ir[25:21]] <= r;
                end
                10'd50: begin msr <= srr1; redirect = 1'b1; target = {srr0[31:2], 2'b00}; end  // rfi
                10'd51: begin msr <= srr3; redirect = 1'b1; target = {srr2[31:2], 2'b00}; end  // rfci
                10'd150: ;                                                        // isync
                default: begin take_exc = 1; ev_esr = 32'h0800_0000; end
                endcase
            end
            6'd20, 6'd21, 6'd23, 6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29,
            6'd8, 6'd12, 6'd13, 6'd14, 6'd15: ;
            6'd31: begin
                case (xo)
                10'd0:   set_cr_field(crfd, cmp_s(va, vb, so));
                10'd32:  set_cr_field(crfd, cmp_u(va, vb, so));
                10'd4:   if (trap(rd, va, vb)) begin take_exc = 1; ev_esr = 32'h0200_0000; end
                10'd19:  begin w1_en = 1'b1; w1_val = cr; end                      // mfcr
                10'd83:  begin w1_en = 1'b1; w1_val = msr; end                     // mfmsr
                10'd144: for (int f = 0; f < 8; f++)                              // mtcrf
                             if (ir[19 - f]) cr[31 - 4*f -: 4] <= vs[31 - 4*f -: 4];
                10'd146: msr <= vs;                                               // mtmsr
                10'd131: msr[15] <= vs[15];                                       // wrtee
                10'd163: msr[15] <= ir[15];                                       // wrteei
                10'd512: begin                                                    // mcrxr
                    set_cr_field(crfd, xer[31:28]);
                    xer[31:28] <= 4'h0;
                end
                10'd339: begin w1_en = 1'b1; w1_val = mfspr_val; end
                10'd467: begin                                                    // mtspr
                    case (sprn)
                    10'h001: xer <= vs;
                    10'h008: lr <= vs;
                    10'h009: ctr <= vs;
                    10'h013: dear_oea <= vs;
                    10'h01a: srr0 <= vs;
                    10'h01b: srr1 <= vs;
                    10'h110: sprg[0] <= vs;
                    10'h111: sprg[1] <= vs;
                    10'h112: sprg[2] <= vs;
                    10'h113: sprg[3] <= vs;
                    10'h3d4: esr <= vs;
                    10'h3d5: dear <= vs;
                    10'h3d6: evpr <= vs;
                    10'h3d7: cdbcr <= vs;
                    10'h3d8: tsr <= tsr & ~vs;
                    10'h3da: begin
                        tcr <= (vs & ~TCR_WRC) | (tcr & TCR_WRC);
                        // MAME restarts the PIT when PIE changes (ppccom.cpp:2206-2208)
                        if (((tcr ^ vs) & TCR_PIE) != 0)
                            pit_count <= ((vs & TCR_PIE) != 0 && pit_reload != 0)
                                         ? {1'b0, pit_reload} + 33'd1 : 33'd0;
                    end
                    10'h3db: begin
                        pit_spr <= vs; pit_reload <= vs;
                        pit_count <= ((tcr & TCR_PIE) != 0 && vs != 0)
                                     ? {1'b0, vs} + 33'd1 : 33'd0;
                    end
                    // MAME: each timebase half write zeroes the other half (ppccom.cpp:2224-2229)
                    10'h3dc: tb <= {vs[23:0], 32'h0};
                    10'h3dd: tb <= {24'h0, vs};
                    10'h3de: srr2 <= vs;
                    10'h3df: srr3 <= vs;
                    10'h3f0: dbsr <= vs;
                    10'h3f2: dbcr <= vs;
                    10'h3f4: iac1 <= vs;
                    10'h3f5: iac2 <= vs;
                    10'h3f6: dac1 <= vs;
                    10'h3f7: dac2 <= vs;
                    10'h3fa: dccr <= vs;
                    10'h3fb: iccr <= vs;
                    10'h3fc: pbl1 <= vs;
                    10'h3fd: pbu1 <= vs;
                    10'h3fe: pbl2 <= vs;
                    10'h3ff: pbu2 <= vs;
                    default: ;
                    endcase
                end
                10'd323: begin w1_en = 1'b1; w1_val = mfdcr_val; end              // mfdcr
                10'd451: case (sprn)                                              // mtdcr
                    10'h040: exisr <= exisr & ~vs;
                    10'h042: exier <= vs;
                    10'h0a0: iocr  <= vs;
                    default: ;
                    endcase
                10'd11, 10'd75, 10'd235, 10'd747: begin                          // mulhwu, mulhw, mullw[o]
                    if (xo9 == 9'd11) begin mul_a <= {1'b0, va};   mul_b <= {1'b0, vb};   end
                    else              begin mul_a <= {va[31], va}; mul_b <= {vb[31], vb}; end
                    xstate <= X_MUL; pop = 1'b0;
                end
                10'd459, 10'd971, 10'd491, 10'd1003: begin                        // divwu, divw
                    logic sg;
                    sg = (xo9 == 9'd491);
                    if (vb == 0 || (sg && va == 32'h8000_0000 && vb == 32'hFFFF_FFFF)) begin
                        // MAME: undefined cases give 0, OV, CR0 = EQ (ppcdrc.cpp:3549-3566)
                        w1_en = 1'b1; w1_val = 32'h0;
                        if (oe) begin xer[30] <= 1'b1; xer[31] <= 1'b1; end
                        if (rc) set_cr_field(3'd0, {3'b001, oe | so});
                        xstate <= X_DONE; pop = 1'b0;
                    end else begin
                        div_neg_q <= sg && (va[31] ^ vb[31]);
                        div_q <= (sg && va[31]) ? -va : va;
                        div_d <= (sg && vb[31]) ? -vb : vb;
                        div_r <= 32'h0;
                        div_n <= 6'd32;
                        xstate <= X_DIV; pop = 1'b0;
                    end
                end
                10'd23, 10'd55, 10'd87, 10'd119, 10'd279, 10'd311, 10'd343, 10'd375,
                10'd151, 10'd183, 10'd215, 10'd247, 10'd407, 10'd439,
                10'd534, 10'd662, 10'd790, 10'd918, 10'd20, 10'd150: ;           // loads/stores below
                10'd597, 10'd533, 10'd725, 10'd661: begin                         // lswi lswx stswi stswx
                    logic [6:0] n;
                    n = (xo == 10'd597 || xo == 10'd725) ? ((rb == 0) ? 7'd32 : {2'b00, rb}) : xer[6:0];
                    mea <= (xo == 10'd597 || xo == 10'd725) ? va0 : va0 + vb;
                    mreg <= rd; mcount <= n; mbyte <= 2'd0;
                    mop <= (xo == 10'd597 || xo == 10'd533) ? M_LSW : M_STSW;
                    xstate <= (n != 0) ? X_MULTI : X_DONE; pop = 1'b0;
                end
                10'd1014: begin                                                   // dcbz
                    // MAME: m_cache_line_size = 32 (ppccom.cpp:715)
                    mea <= (va0 + vb) & ~32'h1F; mcount <= 7'd8; mop <= M_DCBZ;
                    xstate <= X_MULTI; pop = 1'b0;
                end
                // MAME: cache operations are no-ops; dcread/icread write 0 to rD
                10'd86, 10'd470, 10'd54, 10'd278, 10'd246, 10'd982, 10'd262,
                10'd454, 10'd966, 10'd598, 10'd854: ;
                10'd486, 10'd998: begin w1_en = 1'b1; w1_val = 32'h0; end
                default: if (!x_wr) begin take_exc = 1; ev_esr = 32'h0800_0000; end
                endcase
            end
            6'd32, 6'd33, 6'd34, 6'd35, 6'd40, 6'd41, 6'd42, 6'd43,
            6'd36, 6'd37, 6'd38, 6'd39, 6'd44, 6'd45: ;                            // below
            6'd46, 6'd47: begin                                                   // lmw, stmw
                mea <= va0 + simm; mreg <= rd; mop <= (op == 6'd46) ? M_LMW : M_STMW;
                if ((va0 + simm) & 32'h3) begin take_exc = 1; ev = 12'h600; dear_oea <= va0 + simm; end
                else begin xstate <= X_MULTI; pop = 1'b0; end
            end
            default: begin take_exc = 1; ev_esr = 32'h0800_0000; end               // incl. FP
            endcase

            // loads and stores
            if (ls_is) begin
                msize <= ls_sz; msign <= ls_sign; mrev <= ls_rev; mupd <= ls_up;
                mresv <= ls_resv; mea <= ls_ea; mop <= ls_st ? M_STORE : M_LOAD;
                if (ls_misal) begin
                    take_exc = 1; ev = 12'h600; dear_oea <= ls_ea;
                end else if (ls_prot) begin
                    take_exc = 1; ev = 12'h300; dear <= ls_ea;
                end else if (ls_skip) begin
                    // MAME: stwcx. fails on the flag alone, no address compare
                    set_cr_field(3'd0, {3'b000, so});
                    xstate <= X_DONE; pop = 1'b0;
                end else
                    begin xstate <= X_MEM; pop = 1'b0; end
            end

            if (take_exc) begin
                pop = 1'b1;
                xstate <= X_IDLE;
                srr0 <= ev_srr0;
                srr1 <= msr;
                msr  <= (msr & ~(MSR_WE | MSR_PR | MSR_EE | MSR_PE)) & ~32'h1 | {31'h0, msr[16]};
                if (ev == 12'h700) esr <= ev_esr;
                redirect = 1'b1;
                target = {evpr[31:16], 4'h0, ev};
            end
        end

        // ---------------------------------------------------------------- busy states
        case (xstate)
        X_MEM: if (d_ack) begin
            logic [31:0] v;
            v = lane_rd(d_rdata, mea[1:0], msize);
            if (mrev) v = bswap(v, msize);
            else if (msign) v = {{16{v[15]}}, v[15:0]};
            if (mop == M_LOAD) begin w1_en = 1'b1; w1_val = v; end
            if (mupd) begin w2_en = 1'b1; w2_val = mea; end
            if (mresv) begin
                if (mop == M_LOAD) reserve <= 1'b1;
                else begin reserve <= 1'b0; set_cr_field(3'd0, {3'b001, so}); end
            end
            xstate <= X_IDLE; pop = 1'b1;
        end
        X_MUL: xstate <= X_MUL2;             // product registered
        X_MUL2: begin
            logic [31:0] r;
            logic        ovf;
            r   = (op == 6'd31 && (xo9 == 9'd11 || xo9 == 9'd75)) ? mul_p[63:32] : mul_p[31:0];
            ovf = mul_p[63:31] != {33{mul_p[31]}};
            w1_en = 1'b1; w1_val = r;
            if (op == 6'd31 && xo9 == 9'd235 && oe) begin xer[30] <= ovf; if (ovf) xer[31] <= 1'b1; end
            if (op == 6'd31 && rc)
                set_cr_field(3'd0, cr0_of(r, so || (xo9 == 9'd235 && oe && ovf)));
            xstate <= X_IDLE; pop = 1'b1;
        end
        X_DIV: begin
            if (div_n != 0) begin
                logic [32:0] t;
                t = {div_r, div_q[31]} - {1'b0, div_d};
                if (!t[32]) begin div_r <= t[31:0]; div_q <= {div_q[30:0], 1'b1}; end
                else        begin div_r <= {div_r[30:0], div_q[31]}; div_q <= {div_q[30:0], 1'b0}; end
                div_n <= div_n - 6'd1;
            end else begin
                logic [31:0] q;
                q = div_neg_q ? -div_q : div_q;
                w1_en = 1'b1; w1_val = q;
                if (oe) xer[30] <= 1'b0;
                if (rc) set_cr_field(3'd0, cr0_of(q, so));
                xstate <= X_IDLE; pop = 1'b1;
            end
        end
        X_MULTI: xstate <= X_MULTI_WAIT;     // the request goes out this cycle
        X_MULTI_WAIT: if (d_ack) begin
            xstate <= X_MULTI;
            case (mop)
            M_LMW, M_STMW: begin
                // MAME: lmw skips rA except when rA is r31 (ppcdrc.cpp:2937)
                if (mop == M_LMW && (mreg != ra || mreg == 5'd31)) begin
                    w1_en = 1'b1; w1_idx = mreg; w1_val = d_rdata;
                end
                mea  <= mea + 32'd4;
                mreg <= mreg + 5'd1;
                if (mreg == 5'd31) begin xstate <= X_IDLE; pop = 1'b1; end
            end
            M_LSW, M_STSW: begin
                if (mop == M_LSW) begin
                    logic [7:0]  b;
                    logic [31:0] r;
                    b = d_rdata[31 - 8*mea[1:0] -: 8];
                    r = gpr[mreg];
                    // MAME: the first byte clears the register (ppcdrc.cpp:1675)
                    if (mbyte == 2'd0) r = {b, 24'h0};
                    else r[31 - 8*mbyte -: 8] = b;
                    w1_en = 1'b1; w1_idx = mreg; w1_val = r;
                end
                mea    <= mea + 32'd1;
                mcount <= mcount - 7'd1;
                mbyte  <= mbyte + 2'd1;
                if (mbyte == 2'd3) mreg <= mreg + 5'd1;
                if (mcount == 7'd1) begin xstate <= X_IDLE; pop = 1'b1; end
            end
            M_DCBZ: begin
                mea    <= mea + 32'd4;
                mcount <= mcount - 7'd1;
                if (mcount == 7'd1) begin xstate <= X_IDLE; pop = 1'b1; end
            end
            default: begin xstate <= X_IDLE; pop = 1'b1; end
            endcase
        end
        X_DONE: begin xstate <= X_IDLE; pop = 1'b1; end
        default: ;
        endcase

        if (w1_en) gpr[w1_idx] <= w1_val;
        if (w2_en) gpr[w2_idx] <= w2_val;

        // ---------------------------------------------------------------- fetch
        if (redirect) begin
            fetch_pc <= target;
            q_n      <= 2'd0;
            // a request issued this cycle, or one still out, belongs to the old path
            f_out   <= i_req || (f_out && !i_ack);
            f_stale <= i_req || (f_out && !i_ack);
            if (i_req) f_pc <= fetch_pc;
        end else begin
            logic [1:0] n;
            if (i_req) begin
                f_out    <= 1'b1;
                f_stale  <= 1'b0;
                f_pc     <= fetch_pc;
                fetch_pc <= fetch_pc + 32'd4;
            end else if (i_ack) begin
                f_out   <= 1'b0;
                f_stale <= 1'b0;
            end
            n = q_n;
`ifdef SIMULATION
            if (pop != q_pop) $display("ppc403_core: pop %0d q_pop %0d at pc %08x", pop, q_pop, pc);
`endif
            if (q_pop) begin
                q_ir[0] <= q_ir[1]; q_pc[0] <= q_pc[1];
                q_ir[1] <= q_ir[2]; q_pc[1] <= q_pc[2];
                n = n - 2'd1;
            end
            if (f_ack_ok) begin
                q_ir[n] <= i_rdata;
                q_pc[n] <= f_pc;
                n = n + 2'd1;
            end
            q_n <= n;
        end
    end

    if (dbg_we) begin
        case (dbg_wsel)
        6'd32: cr <= dbg_wdata;
        6'd33: lr <= dbg_wdata;
        6'd34: ctr <= dbg_wdata;
        6'd35: xer <= dbg_wdata;
        6'd36: msr <= dbg_wdata;
        6'd37: fetch_pc <= dbg_wdata;
        6'd38: srr0 <= dbg_wdata;
        6'd39: srr1 <= dbg_wdata;
        6'd40: sprg[0] <= dbg_wdata;
        6'd41: sprg[1] <= dbg_wdata;
        6'd42: sprg[2] <= dbg_wdata;
        6'd43: sprg[3] <= dbg_wdata;
        6'd44: exier <= dbg_wdata;
        6'd45: evpr <= dbg_wdata;
        6'd46: tb[31:0] <= dbg_wdata;
        6'd47: tb[55:32] <= dbg_wdata[23:0];
        6'd48: tcr <= dbg_wdata;
        6'd49: tsr <= tsr | dbg_wdata;
        6'd50: exisr <= dbg_wdata;
        6'd51: iocr <= dbg_wdata;
        6'd52: begin pit_spr <= dbg_wdata; pit_reload <= dbg_wdata; end
        6'd53: pit_count <= {1'b0, dbg_wdata};
        6'd54: irqstate <= dbg_wdata[4:0];
        default: if (dbg_wsel < 6'd32) gpr[dbg_wsel[4:0]] <= dbg_wdata;
        endcase
    end
end

endmodule
