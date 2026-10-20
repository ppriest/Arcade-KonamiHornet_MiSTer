// SPDX-License-Identifier: GPL-3.0-or-later
//
// sharc2_core's X-stage work, included inside the module: v1's sharc_core_ops.svh (MAME's
// sharcops.hxx, sharc.cpp) split into micro-ops. Each micro-op reads the registered state Q (and
// the handler's view of the PC queue, hv_*) and writes the clock's work `c`; micro-ops that run in
// one clock write disjoint state, or ASTAT/STKY through clear/set masks split at the compute
// point. R, DAG and PC-stack writes are requests applied at the X edge.

// ------------------------------------------------------------------------------------------
// Flags
// ------------------------------------------------------------------------------------------

function automatic logic [63:0] mask_then(input logic [63:0] m1, input logic [31:0] clr, input logic [31:0] set);
    // {clr, set} of m1 followed by (clr, set)
    mask_then = {m1[63:32] | clr, (m1[31:0] & ~clr) | set};
endfunction

task automatic astat_upd(inout xc_t c, input logic [31:0] clr, input logic [31:0] set);
    if (!c.cp) c.apre = mask_then(c.apre, clr, set); else c.apost = mask_then(c.apost, clr, set);
endtask
task automatic stky_upd(inout xc_t c, input logic [31:0] clr, input logic [31:0] set);
    if (!c.cp) c.spre = mask_then(c.spre, clr, set); else c.spost = mask_then(c.spost, clr, set);
endtask

// ASTAT and STKY as the handler and the stack micro-ops read them: Q's, as no micro-op that
// changes them shares their clock; valid when W has no flag update pending, which the X interlock
// ensures for every instruction that reads them
function automatic logic [31:0] astat_now(input xc_t c);
    astat_now = Q.astat;
endfunction
function automatic logic [31:0] stky_now(input xc_t c);
    stky_now = Q.stky;
endfunction

function automatic logic cond_lt(input logic [31:0] a, input logic [31:0] mode1);
    cond_lt = (a & AF) ? ((a & AN) != 0 && (a & AZ) == 0)
                       : (((a & AN) != 0) != (((a & AV) != 0) && (mode1 & MODE1_ALUSAT) == 0));
endfunction
function automatic logic cond_le(input logic [31:0] a, input logic [31:0] mode1);
    cond_le = (a & AZ) != 0 ||
              ((a & AF) ? (a & AN) != 0
                        : (((a & AN) != 0) != (((a & AV) != 0) && (mode1 & MODE1_ALUSAT) == 0)));
endfunction

// a condition code on ASTAT `a` with Q's MODE1, flags and loop counter
function automatic logic cond_on(input logic [31:0] a, input logic [4:0] cc);
    case (cc)
    5'h00: cond_on = (a & AZ) != 0;
    5'h01: cond_on = cond_lt(a, Q.mode1);
    5'h02: cond_on = cond_le(a, Q.mode1);
    5'h03: cond_on = (a & AC) != 0;
    5'h04: cond_on = (a & AV) != 0;
    5'h05: cond_on = (a & MV) != 0;
    5'h06: cond_on = (a & MN) != 0;
    5'h07: cond_on = (a & SV) != 0;
    5'h08: cond_on = (a & SZ) != 0;
    5'h09: cond_on = Q.flag[0];
    5'h0a: cond_on = Q.flag[1];
    5'h0b: cond_on = Q.flag[2];
    5'h0c: cond_on = Q.flag[3];
    5'h0d: cond_on = (a & BTF) != 0;
    5'h0e: cond_on = 1'b0;
    5'h0f: cond_on = Q.curlcntr != 1;
    5'h10: cond_on = (a & AZ) == 0;
    5'h11: cond_on = !cond_lt(a, Q.mode1);
    5'h12: cond_on = !cond_le(a, Q.mode1);
    5'h13: cond_on = (a & AC) == 0;
    5'h14: cond_on = (a & AV) == 0;
    5'h15: cond_on = (a & MV) == 0;
    5'h16: cond_on = (a & MN) == 0;
    5'h17: cond_on = (a & SV) == 0;
    5'h18: cond_on = (a & SZ) == 0;
    5'h19: cond_on = !Q.flag[0];
    5'h1a: cond_on = !Q.flag[1];
    5'h1b: cond_on = !Q.flag[2];
    5'h1c: cond_on = !Q.flag[3];
    5'h1d: cond_on = (a & BTF) == 0;
    default: cond_on = 1'b1;
    endcase
endfunction
function automatic logic if_cond(input xc_t c, input logic [4:0] cc);
    if_cond = cond_on(astat_now(c), cc);
endfunction

// ------------------------------------------------------------------------------------------
// Stacks (one PC-stack array write a clock)
// ------------------------------------------------------------------------------------------

task automatic pcs_wr(inout xc_t c, input logic [31:0] i, input logic [31:0] d);
    if (i < 30) begin c.psw = 1'b1; c.psi = i[4:0]; c.psd = d; end
endtask

task automatic change_pc(inout xc_t c, input logic [31:0] newpc);
    c.s.pc = newpc; c.s.daddr = newpc; c.s.faddr = newpc + 1; c.s.nfaddr = newpc + 2;
endtask

// push_pc from Q, then PCSTK = v if `set`
task automatic op_push_pc(inout xc_t c, input logic set, input logic [31:0] v);
    if (Q.pcstkp > 0) pcs_wr(c, Q.pcstkp - 1, Q.pcstk);
    c.s.pcstkp = Q.pcstkp + 1;
    stky_upd(c, PCEM, 32'h0);
    if (Q.pcstkp + 1 >= 30) stky_upd(c, 32'h0, PCFL);
    if (set) c.s.pcstk = v;
endtask

// pop_pc from Q: the value popped is Q.pcstk
task automatic op_pop_pc(inout xc_t c);
    logic [31:0] p;
    p = Q.pcstkp - 1;
    c.s.pcstkp = p;
    if (p < 30) begin
        pcs_wr(c, p, Q.pcstk);
        if (p > 0) c.s.pcstk = pcs_rd;
        else begin c.s.pcstk = 32'h00FF_FFFF; stky_upd(c, 32'h0, PCEM); end
        stky_upd(c, PCFL, 32'h0);
    end
endtask

function automatic logic [31:0] laddr_pack(input laddr_t l);
    laddr_pack = {l.loop_type, 1'b0, l.code, l.addr[23:0]};
endfunction
function automatic laddr_t laddr_unpack(input logic [31:0] v);
    laddr_unpack.addr = {8'h0, v[23:0]};
    laddr_unpack.code = v[28:24];
    laddr_unpack.loop_type = v[31:30];
endfunction

task automatic op_push_loop(inout xc_t c);
    if (Q.lstkp > 0) begin
        c.s.lcstack[Q.lstkp - 1] = Q.curlcntr;
        c.s.lastack[Q.lstkp - 1] = laddr_pack(Q.laddr);
    end
    c.s.curlcntr = Q.lcntr;
    c.s.laddr = laddr_unpack(Q.lastack[Q.lstkp]);
    c.s.lstkp = Q.lstkp + 1;
    if (Q.lstkp + 1 < 6) c.s.lcntr = Q.lcstack[Q.lstkp + 1];
    else c.s.lcntr = 32'hFFFF_FFFF;
    stky_upd(c, LSEM, 32'h0);
endtask

// pop_loop from Q; LCNTR takes `cur` (CURLCNTR as the popping step left it)
task automatic op_pop_loop(inout xc_t c, input logic [31:0] cur);
    logic [31:0] p;
    p = Q.lstkp - 1;
    c.s.lstkp = p;
    c.s.lcntr = cur;
    c.s.lastack[p] = laddr_pack(Q.laddr);
    if (p > 0) begin
        c.s.curlcntr = Q.lcstack[p - 1];
        c.s.laddr = laddr_unpack(Q.lastack[p - 1]);
    end else begin
        c.s.curlcntr = 32'hFFFF_FFFF;
        c.s.laddr = laddr_unpack(32'hFFFF_FFFF);
        stky_upd(c, 32'h0, LSEM);
    end
endtask

function automatic logic [31:0] astat_read(input xc_t c);
    logic [31:0] r;
    r = astat_now(c) & ({28'h0, Q.mode2[18:15]} << 19 | ~FLGS);
    for (int i = 0; i < 4; i++)
        if (!Q.mode2[15 + i]) r = r | ({31'h0, Q.flag[i]} << (19 + i));
    astat_read = r;
endfunction

task automatic op_push_status(inout xc_t c);
    c.s.status_stkp = Q.status_stkp + 1;
    c.s.ss_mode1[Q.status_stkp] = Q.mode1;
    c.s.ss_astat[Q.status_stkp] = astat_read(c);
    stky_upd(c, SSEM, 32'h0);
endtask

task automatic sysreg_latency_effect(inout xc_t c);
    logic [31:0] diff;
    diff = Q.lat_data ^ Q.lat_prev;
    c.s.mode1 = Q.lat_data;
    // the register-set swaps wait for the pipeline to drain (swap_req)
    c.swap = {diff[10] != 0, diff[7] != 0, diff[6] != 0, diff[5] != 0, diff[4] != 0, diff[3] != 0};
    c.s.lat_reg = 32'hFFFF_FFFF;
endtask

// MODE1 written with `d` (add_latency from Q, then MODE1)
task automatic mode1_write(inout xc_t c, input logic [31:0] d);
    if (Q.lat_cycles > 0) sysreg_latency_effect(c);
    c.s.lat_cycles = 2;
    c.s.lat_reg = 32'hb;
    c.s.lat_data = d;
    c.s.lat_prev = Q.mode1;
    c.s.mode1 = d;
endtask

task automatic op_pop_status(inout xc_t c);
    logic [31:0] p;
    p = Q.status_stkp - 1;
    c.s.status_stkp = p;
    mode1_write(c, Q.ss_mode1[p]);
    // set_ureg(ASTAT, (astat & FLGS) | (ss & ~FLGS)): the flag bits kept
    astat_upd(c, ~FLGS, Q.ss_astat[p] & ~FLGS);
    if (p == 0) stky_upd(c, 32'h0, SSEM);
endtask

// check_interrupts from Q with irq_pending `pend`: taken or not
function automatic logic irq_take(input logic [31:0] pend);
    irq_take = (Q.imask & pend) != 0 && (Q.mode1 & MODE1_IRPTEN) != 0 && !Q.interrupt_active &&
               Q.pc != Q.delay_slot1 && Q.pc != Q.delay_slot2;
endfunction
function automatic logic [4:0] irq_which(input logic [31:0] pend);
    irq_which = 5'd0;
    for (int i = 31; i >= 0; i--) if (pend[i]) irq_which = 5'(i);
endfunction
function automatic logic [31:0] irq_vector(input logic [31:0] pend);
    irq_vector = 32'h20000 + {25'h0, irq_which(pend), 2'b00};
endfunction
// check_interrupts' taking of the interrupt, but its push_pc (PCSTK = IDLE ? PC + 1 : DADDR) and
// push_status (`push_st`), which the core runs once for every micro-op that needs them
task automatic irq_core(inout xc_t c, input logic [31:0] pend, output logic push_st);
    logic [4:0] which;
    which = irq_which(pend);
    c.s.irptl = Q.irptl | (32'h1 << which);
    push_st = which >= 6 && which <= 8;
    change_pc(c, irq_vector(pend));
    c.s.active_irq_num = {27'h0, which};
    c.s.irq_pending = pend & ~(32'h1 << which);
    c.s.interrupt_active = 1'b1;
    c.irq_taken = 1'b1;
endtask

// ------------------------------------------------------------------------------------------
// Universal registers
// ------------------------------------------------------------------------------------------

// DAG registers: kind 0 I, 1 M, 2 L, 3 B
// X's read of a DAG register: the array's X copy, which reads register i (dgx_i)
function automatic logic [31:0] dag_rd(input logic g, input logic [1:0] k, input logic [2:0] i);
    dag_rd = dgx_q[{g, k}];
endfunction

function automatic logic [31:0] get_ureg(input xc_t c, input logic [7:0] u);
    logic [2:0] k;
    k = u[2:0];
    case (u[7:4])
    4'h0: get_ureg = xs1;                              // D put R[u] in slot S1
    4'h1: get_ureg = dag_rd(u[3], 2'd0, k);
    4'h2: get_ureg = u[3] ? {{8{dgx_q[5][23]}}, dgx_q[5][23:0]} : dgx_q[1];
    4'h3: get_ureg = dag_rd(u[3], 2'd2, k);
    4'h4: get_ureg = dag_rd(u[3], 2'd3, k);
    4'h6: case (u[3:0])
          4'h4: get_ureg = Q.pcstk;
          4'h5: get_ureg = Q.pcstkp;
          4'h7: get_ureg = Q.curlcntr;
          4'h8: get_ureg = Q.lcntr;
          default: get_ureg = 32'h0;
          endcase
    4'h7: case (u[3:0])
          4'h0: get_ureg = Q.ustat1;
          4'h1: get_ureg = Q.ustat2;
          4'h9: get_ureg = Q.irptl;
          4'ha: get_ureg = Q.mode2;
          4'hb: get_ureg = Q.mode1;
          4'hc: get_ureg = astat_read(c);
          4'hd: get_ureg = Q.imask;
          4'he: get_ureg = stky_now(c);
          default: get_ureg = 32'h0;
          endcase
    4'hd: case (u[3:0])
          4'hb: get_ureg = Q.px[31:0];
          4'hc: get_ureg = {16'h0, Q.px[15:0]};
          4'hd: get_ureg = Q.px[47:16];
          default: get_ureg = 32'h0;
          endcase
    default: get_ureg = 32'h0;
    endcase
endfunction

// a universal register write that runs beside the handler: R, DAG and the plain system registers.
// PCSTK, PCSTKP, CURLCNTR, LCNTR, MODE1 and IMASK take a clock of their own (op_ureg)
function automatic logic ureg_simple(input logic [7:0] u);
    ureg_simple = !(u == 8'h64 || u == 8'h65 || u == 8'h67 || u == 8'h68 || u == 8'h7b || u == 8'h7d);
endfunction

task automatic op_ureg(inout xc_t c, input logic [7:0] u, input logic [31:0] d);
    logic [2:0] k;
    k = u[2:0];
    case (u[7:4])
    4'h0: begin c.uwe = 1'b1; c.ur = u[3:0]; c.ud = d; end
    4'h1, 4'h2, 4'h3, 4'h4: begin
        c.dwe = 1'b1; c.dg = u[3]; c.di = k; c.dd = d;
        c.dk = (u[7:4] == 4'h1) ? 2'd0 : (u[7:4] == 4'h2) ? 2'd1 : (u[7:4] == 4'h3) ? 2'd2 : 2'd3;
    end
    4'h6: case (u[3:0])
          4'h4: if (Q.pcstkp > 0 && Q.pcstkp < 31) c.s.pcstk = d & 32'h00FF_FFFF;
          4'h5: if (Q.pcstkp < 31) begin
                    logic [31:0] nw;
                    nw = d & 32'h1F;
                    c.s.pcstkp = nw;
                    if (Q.pcstkp > 0) pcs_wr(c, Q.pcstkp - 1, Q.pcstk);
                    if (Q.pcstkp < nw) begin
                        c.s.pcstk = pcs_rd;
                        stky_upd(c, PCEM, 32'h0);
                        if (nw >= 30) stky_upd(c, 32'h0, PCFL);
                    end else if (Q.pcstkp > nw) begin
                        if (nw > 0) c.s.pcstk = pcs_rd;
                        else begin c.s.pcstk = 32'h00FF_FFFF; stky_upd(c, 32'h0, PCEM); end
                        stky_upd(c, PCFL, 32'h0);
                    end
                end
          4'h7: if (Q.lstkp > 0 && Q.lstkp < 7) c.s.curlcntr = d;
          4'h8: if (Q.lstkp < 6) c.s.lcntr = d;
          default: ;
          endcase
    4'h7: case (u[3:0])
          4'h0: c.s.ustat1 = d;
          4'h1: c.s.ustat2 = d;
          4'h9: c.s.irptl = d;
          4'ha: c.s.mode2 = d;
          4'hb: mode1_write(c, d);
          4'hc: astat_upd(c, 32'hFFFF_FFFF, d);
          4'hd: ;                                       // IMASK: op_chk, after the check
          4'he: stky_upd(c, ~(LSEM | 32'h0200_0000 | SSEM | SSOV | PCEM | PCFL),
                         d & ~(LSEM | 32'h0200_0000 | SSEM | SSOV | PCEM | PCFL));
          default: ;
          endcase
    4'hd: case (u[3:0])
          4'hc: c.s.px = {Q.px[47:16], d[15:0]};
          4'hd: c.s.px = {d, Q.px[15:0]};
          default: ;
          endcase
    default: ;
    endcase
endtask

// the universal register an instruction reads as a source (all forms read it before changing
// anything)
function automatic logic [7:0] usrc_sel(input logic [47:0] op);
    casez (op[47:39])
    9'b0100?????, 9'b0101?????: usrc_sel = op[30:23];
    9'b0111?????: usrc_sel = op[43:36];
    9'b00010100?: usrc_sel = {4'h7, op[35:32]};
    9'b00001100?, 9'b00001101?, 9'b00001110?, 9'b000100???, 9'b101??????: usrc_sel = op[39:32];
    default: usrc_sel = 8'h0;
    endcase
endfunction

// the instruction's handler reads or writes what a loop end changes (the PC queue, the PC and loop
// stacks, the loop registers, STKY): with a loop end it runs in the clock after
function automatic logic loop_conflict(input logic [47:0] op);
    logic [7:0] u;
    u = usrc_sel(op);
    casez (op[47:39])
    9'b0000011??, 9'b0000100??, 9'b110??????, 9'b111??????, 9'b00001010?, 9'b00001011?,
    9'b00001100?, 9'b00001101?, 9'b00001110?, 9'b00010111?, 9'b000000001: loop_conflict = 1'b1;
    9'b0111?????: loop_conflict = u[7:4] == 4'h6 || u == 8'h7e || op[30:27] == 4'h6 || op[30:23] == 8'h7e;
    9'b00001111?: loop_conflict = op[39:36] == 4'h6 || op[39:32] == 8'h7e;
    9'b00010100?: loop_conflict = op[35:32] == 4'he;
    default: loop_conflict = u[7:4] == 4'h6 || u == 8'h7e;
    endcase
endfunction

// ------------------------------------------------------------------------------------------
// DAG post-modify: one write per DAG a clock
// ------------------------------------------------------------------------------------------

// I + M (or the immediate) `v`, wrapped into the circular buffer
function automatic logic [31:0] pm_wrap(input logic g, input logic [2:0] i, input logic [31:0] v);
    logic [31:0] b, l;
    l = dgx_q[{g, 2'd2}];
    b = dgx_q[{g, 2'd3}];
    pm_wrap = v;
    if (l != 0) begin
        if (v > b + l) pm_wrap = v - l;
        else if (v < b) pm_wrap = v + l;
    end
endfunction
// as D made it (x_pd)
task automatic post_modify_s(inout xc_t c, input logic g, input logic [2:0] i, input logic [31:0] sum);
    c.pwe[g] = 1'b1; c.pi[g] = i; c.pd[g] = x_pd[g];
endtask
// from I as it is now (after a load into a DAG register)
task automatic post_modify(inout xc_t c, input logic g, input logic [2:0] i, input logic [31:0] m);
    c.pwe[g] = 1'b1; c.pi[g] = i; c.pd[g] = pm_wrap(g, i, dgx_q[{g, 2'd0}] + m);
endtask

task automatic q_acc(inout xc_t c, input acc_kind_t kind, input logic [31:0] addr,
                     input logic [47:0] wdata, input logic [1:0] dkind, input logic [7:0] dest,
                     input logic pmod, input logic ppm, input logic [2:0] pi, input logic [31:0] pmv,
                     input logic [31:0] pms);
    acc_t e;
    e.valid = 1'b1; e.kind = kind; e.addr = addr; e.wdata = wdata;
    e.dest_kind = dkind; e.dest = dest;
    e.post_mod = pmod; e.post_pm = ppm; e.post_i = pi; e.post_m = pmv; e.post_s = pms;
    c.a[c.n[0]] = e;
    c.n = c.n + 2'd1;
endtask

// ------------------------------------------------------------------------------------------
// IOP registers: written into the next state at the commit (XS_WAIT's c.iow)
// ------------------------------------------------------------------------------------------

task automatic iop_write(inout q_t n, input logic [7:0] a, input logic [31:0] d);
    case (a)
    8'h00: n.syscon = d;
    8'h1c: begin n.dma_control[0] = d;
                 if (d[0]) begin n.iop_delay_reg = 32'h1c; n.iop_delay_data = d; n.iop_delay_cycles = 1; end end
    8'h1d: begin n.dma_control[1] = d;
                 if (d[0]) begin n.iop_delay_reg = 32'h1d; n.iop_delay_data = d; n.iop_delay_cycles = 30; end end
    8'h40: n.dma_int_index[0] = d;
    8'h41: n.dma_int_modifier[0] = d;
    8'h42: n.dma_int_count[0] = d;
    8'h43: n.dma_chain_ptr[0] = d;
    8'h44: n.dma_gen[0] = d;
    8'h45: n.dma_ext_index[0] = d;
    8'h46: n.dma_ext_modifier[0] = d;
    8'h47: n.dma_ext_count[0] = d;
    8'h48: n.dma_int_index[1] = d;
    8'h49: n.dma_int_modifier[1] = d;
    8'h4a: n.dma_int_count[1] = d;
    8'h4b: n.dma_chain_ptr[1] = d;
    8'h4c: n.dma_gen[1] = d;
    8'h4d: n.dma_ext_index[1] = d;
    8'h4e: n.dma_ext_modifier[1] = d;
    8'h4f: n.dma_ext_count[1] = d;
    default: ;
    endcase
endtask

// after the accesses: system-register latency and the delayed IOP write, in instructions
task automatic post_counters(inout xc_t c);
    if (Q.lat_cycles != 0) begin
        c.s.lat_cycles = Q.lat_cycles - 1;
        if (Q.lat_cycles == 1) sysreg_latency_effect(c);
    end
    if (Q.iop_delay_cycles != 0) begin
        c.s.iop_delay_cycles = Q.iop_delay_cycles - 1;
        if (Q.iop_delay_cycles == 1 && Q.iop_delay_data[0]) begin
            c.dma_exec = 1'b1;
            c.dma_exec_ch = Q.iop_delay_reg != 32'h1c;
        end
    end
endtask

// ------------------------------------------------------------------------------------------
// Opcode handlers (v1 execute_op): the compute, the accesses, and requests for what follows.
// The compute is the ALU's: apply_compute marks the point
// ------------------------------------------------------------------------------------------

function automatic logic [31:0] sext24(input logic [23:0] v);
    sext24 = {{8{v[23]}}, v};
endfunction
function automatic logic [31:0] sext6(input logic [5:0] v);
    sext6 = {{26{v[5]}}, v};
endfunction

task automatic apply_compute(inout xc_t c);
    c.compute = 1'b1;
    c.cp = 1'b1;
    c.c_mode1 = Q.mode1;
    c.c_astat = astat_now(c);
endtask

// the DAG registers a form reads, as two ports read once: DAG1 (I, M) and DAG2 (I, M). Forms
// with a DAG select bit give both ports the same indices
task automatic dag_ports(inout xc_t c);
    c.rI1 = x_dI[0]; c.rM1 = x_dM[0]; c.rI2 = x_dI[1]; c.rM2 = x_dM[1];
endtask
function automatic logic [31:0] dI(input xc_t c, input logic g);
    dI = g ? c.rI2 : c.rI1;
endfunction
function automatic logic [31:0] dM(input xc_t c, input logic g);
    dM = g ? c.rM2 : c.rM1;
endfunction

// a jump's CI bit clears the interrupt before the handler (op_clearint): 0x0600/0x0700 under the
// condition (evaluated before it, `pc`), 0x0800-0x0980 always
function automatic logic ci_needed(input logic [47:0] op, input logic pc);
    casez (op[47:39])
    9'b0000011??: ci_needed = op[24] && !op[39] && pc;
    9'b000010000, 9'b000010010: ci_needed = op[24];
    default: ci_needed = 1'b0;
    endcase
endfunction

task automatic req_jump(inout xc_t c, input logic j, input logic [31:0] t);
    c.r_jump = 1'b1; c.r_j = j; c.r_target = t;
endtask
task automatic req_call(inout xc_t c, input logic j, input logic [31:0] t, input logic [31:0] ret);
    c.r_push_pc = 1'b1; c.r_pcstk = 1'b1; c.r_pcstk_v = ret;
    req_jump(c, j, t);
endtask
task automatic set_ureg(inout xc_t c, input logic [7:0] u, input logic [31:0] d);
    c.ureq = 1'b1; c.uq_u = u; c.uq_d = d;
endtask

// `pre_cond`: a 0x0600/0x0700 jump's condition, evaluated before its clear_int
task automatic execute_op(inout xc_t c, input logic [47:0] op, input logic pre_cond);
    logic [4:0]  cond;
    logic [22:0] comp;
    logic        j, e, la;
    cond = op[37:33];
    comp = op[22:0];
    j = op[26]; e = op[25]; la = op[38];

    casez (op[47:39])
    9'b001??????: begin
        logic [3:0]  pmd_r, dmd_r;
        logic [2:0]  pmi, dmi;
        pmd_r = op[26:23]; dmd_r = op[36:33]; pmi = op[32:30]; dmi = op[43:41];
        if (comp != 0) apply_compute(c);
        if (op[37]) q_acc(c, A_PM_WR32, c.rI2, {xs2, 16'h0}, 2'd3, 8'h0, 1'b1, 1'b1, pmi, c.rM2, x_sM[1]);
        else        q_acc(c, A_PM_RD32, c.rI2, 48'h0, 2'd0, {4'h0, pmd_r}, 1'b1, 1'b1, pmi, c.rM2, x_sM[1]);
        if (op[44]) q_acc(c, A_DM_WR, c.rI1, {16'h0, xs1}, 2'd3, 8'h0, 1'b1, 1'b0, dmi, c.rM1, x_sM[0]);
        else        q_acc(c, A_DM_RD, c.rI1, 48'h0, 2'd0, {4'h0, dmd_r}, 1'b1, 1'b0, dmi, c.rM1, x_sM[0]);
    end
    9'b000000010, 9'b000000011: if (if_cond(c, cond) && comp != 0) apply_compute(c);
    9'b0100?????, 9'b0101?????: begin
        logic g, d, post;
        logic [7:0] u;
        logic [31:0] ad, mv;
        g = op[32]; d = op[31]; u = op[30:23]; post = op[44];
        if (if_cond(c, op[37:33])) begin
            if (comp != 0) apply_compute(c);
            mv = dM(c, g);
            ad = post ? dI(c, g) : x_sM[g];
            if (g) begin
                if (d) q_acc(c, (u == 8'hdb) ? A_PM_WR48 : A_PM_WR32, ad,
                             (u == 8'hdb) ? Q.px : {c.usrc, 16'h0}, 2'd3, 8'h0, post, 1'b1, op[43:41], mv, x_sM[1]);
                else   q_acc(c, (u == 8'hdb) ? A_PM_RD48 : A_PM_RD32, ad, 48'h0,
                             (u == 8'hdb) ? 2'd2 : 2'd1, u, post, 1'b1, op[43:41], mv, x_sM[1]);
            end else begin
                if (d) q_acc(c, A_DM_WR, ad, {16'h0, c.usrc}, 2'd3, 8'h0, post, 1'b0, op[43:41], mv, x_sM[0]);
                else   q_acc(c, A_DM_RD, ad, 48'h0, 2'd1, u, post, 1'b0, op[43:41], mv, x_sM[0]);
            end
        end
    end
    9'b0110???0?, 9'b0110???1?: begin
        logic u, g, d;
        logic [3:0] dr;
        logic [31:0] mv, ad;
        u = op[38]; g = op[40]; d = op[39]; dr = op[26:23];
        mv = sext6(op[32:27]);
        if (if_cond(c, cond)) begin
            if (comp != 0) apply_compute(c);
            ad = u ? dI(c, g) : x_sX[g];
            if (d) q_acc(c, g ? A_PM_WR32 : A_DM_WR, ad, g ? {xs1, 16'h0} : {16'h0, xs1}, 2'd3, 8'h0, u, g, op[43:41], mv, x_sX[g]);
            else   q_acc(c, g ? A_PM_RD32 : A_DM_RD, ad, 48'h0, 2'd0, {4'h0, dr}, u, g, op[43:41], mv, x_sX[g]);
        end
    end
    9'b0111?????: if (if_cond(c, op[35:31])) begin
        if (comp != 0) apply_compute(c);
        set_ureg(c, op[30:23], c.usrc);
    end
    9'b1000?????: begin
        logic g, d;
        logic [3:0] dr;
        g = op[32]; d = op[31]; dr = op[26:23];
        if (if_cond(c, cond)) begin
            c.shimm = 1'b1;
            apply_compute(c);
            if (d) q_acc(c, g ? A_PM_WR32 : A_DM_WR, dI(c, g), g ? {xs1, 16'h0} : {16'h0, xs1}, 2'd3, 8'h0, 1'b1, g, op[43:41], dM(c, g), x_sM[g]);
            else   q_acc(c, g ? A_PM_RD32 : A_DM_RD, dI(c, g), 48'h0, 2'd0, {4'h0, dr}, 1'b1, g, op[43:41], dM(c, g), x_sM[g]);
        end
    end
    9'b000000100, 9'b000000101: if (if_cond(c, cond)) begin c.shimm = 1'b1; apply_compute(c); end
    9'b000001000, 9'b000001001: if (if_cond(c, cond)) begin
        if (comp != 0) apply_compute(c);
        c.pmr[op[38]] = 1'b1; c.pmi[op[38]] = op[32:30]; c.pmm[op[38]] = dM(c, op[38]); c.pms[op[38]] = x_sM[op[38]];
    end
    // direct and relative jumps and calls (0x0600-0x0780): CI is op_clearint's
    9'b0000011??: if (pre_cond) begin
        logic [31:0] t;
        t = op[40] ? hv_pc + sext24(op[23:0]) : {8'h0, op[23:0]};
        if (!op[39]) begin
            if (la) begin c.r_pop_pc = 1'b1; c.r_pop_loop = 1'b1; end
            req_jump(c, j, t);
        end else
            req_call(c, j, t, j ? (op[40] ? hv_pc + 3 : hv_nfaddr) : (op[40] ? hv_pc + 1 : hv_daddr));
    end
    // indirect / PC-relative jumps and calls with compute (0x0800-0x0980)
    9'b0000100??: begin
        logic [31:0] t;
        t = op[40] ? hv_pc + sext6(op[32:27]) : x_sM[1];
        if (e) begin
            if (if_cond(c, cond)) begin
                if (!op[39]) begin
                    if (la) begin c.r_pop_pc = 1'b1; c.r_pop_loop = 1'b1; end
                    req_jump(c, j, t);
                end else req_call(c, j, t, j ? hv_nfaddr : hv_daddr);
            end else if (comp != 0) apply_compute(c);
        end else if (if_cond(c, cond)) begin
            if (comp != 0) apply_compute(c);
            if (!op[39]) begin
                if (la) begin c.r_pop_pc = 1'b1; c.r_pop_loop = 1'b1; end
                req_jump(c, j, t);
            end else req_call(c, j, t, j ? hv_nfaddr : hv_daddr);
        end
    end
    9'b110??????, 9'b111??????: begin
        logic [3:0] dr;
        dr = op[26:23];
        if (if_cond(c, cond)) req_jump(c, 1'b0, op[45] ? hv_pc + sext6(op[32:27]) : x_sM[1]);
        else begin
            if (comp != 0) apply_compute(c);
            if (op[44]) q_acc(c, A_DM_WR, c.rI1, {16'h0, xs1}, 2'd3, 8'h0, 1'b1, 1'b0, op[43:41], c.rM1, x_sM[0]);
            else        q_acc(c, A_DM_RD, c.rI1, 48'h0, 2'd0, {4'h0, dr}, 1'b1, 1'b0, op[43:41], c.rM1, x_sM[0]);
        end
    end
    9'b00001010?, 9'b00001011?: begin
        logic rti;
        rti = op[40];
        if (rti) c.s.irptl = Q.irptl & ~(32'h1 << Q.active_irq_num[4:0]);
        if (e) begin
            if (if_cond(c, cond)) begin c.r_pop_pc = 1'b1; c.r_jump = 1'b1; c.r_jpop = 1'b1; c.r_j = j; end
            else if (comp != 0) apply_compute(c);
        end else if (if_cond(c, cond)) begin
            if (comp != 0) apply_compute(c);
            c.r_pop_pc = 1'b1; c.r_jump = 1'b1; c.r_jpop = 1'b1; c.r_j = j;
        end
        if (rti) begin
            if (Q.active_irq_num >= 6 && Q.active_irq_num <= 8) c.r_pop_status = 1'b1;
            c.r_rti = 1'b1;
        end
    end
    9'b00001100?, 9'b00001101?, 9'b00001110?: begin
        logic [31:0] off, ldist;
        off = sext24(op[23:0]);
        ldist = off[31] ? -off : off;
        if (op[42:40] == 3'b100) c.s.lcntr = {16'h0, op[39:24]};
        else if (op[42:40] == 3'b101) c.s.lcntr = c.usrc;
        c.r_push_pc = 1'b1; c.r_pcstk = 1'b1; c.r_pcstk_v = hv_pc + 1;
        c.r_push_loop = 1'b1;
        c.r_do = 1'b1;
        c.r_laddr.addr = hv_pc + off;
        if (op[42:40] == 3'b110) begin
            c.r_laddr.code = cond;
            c.r_laddr.loop_type = 2'd0;
        end else begin
            c.r_laddr.code = 5'hf;
            c.r_laddr.loop_type = (ldist == 1) ? 2'd1 : (ldist == 2) ? 2'd2 : 2'd3;
        end
    end
    9'b00001111?: set_ureg(c, op[39:32], op[31:0]);
    9'b000100???: begin
        logic [7:0] u;
        u = op[39:32];
        case (op[41:40])
        2'b00: q_acc(c, A_DM_RD, op[31:0], 48'h0, 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
        2'b01: q_acc(c, A_DM_WR, op[31:0], {16'h0, c.usrc}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
        2'b10: q_acc(c, (u == 8'hdb) ? A_PM_RD48 : A_PM_RD32, op[31:0], 48'h0,
                     (u == 8'hdb) ? 2'd2 : 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
        default: q_acc(c, (u == 8'hdb) ? A_PM_WR48 : A_PM_WR32, op[31:0],
                       (u == 8'hdb) ? Q.px : {c.usrc, 16'h0}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
        endcase
    end
    9'b101??????: begin
        logic [7:0] u;
        logic g, d;
        logic [31:0] ad;
        u = op[39:32]; g = op[44]; d = op[40];
        ad = g ? x_sX[1] : x_sX[0];
        if (g) begin
            if (d) q_acc(c, (u == 8'hdb) ? A_PM_WR48 : A_PM_WR32, ad,
                         (u == 8'hdb) ? Q.px : {c.usrc, 16'h0}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
            else   q_acc(c, (u == 8'hdb) ? A_PM_RD48 : A_PM_RD32, ad, 48'h0,
                         (u == 8'hdb) ? 2'd2 : 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
        end else begin
            if (d) q_acc(c, A_DM_WR, ad, {16'h0, c.usrc}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
            else   q_acc(c, A_DM_RD, ad, 48'h0, 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0, 32'h0);
        end
    end
    9'b1001?????: begin
        logic g;
        g = op[37];
        q_acc(c, g ? A_PM_WR32 : A_DM_WR, dI(c, g), g ? {op[31:0], 16'h0} : {16'h0, op[31:0]}, 2'd3, 8'h0, 1'b1, g, op[43:41], dM(c, g), x_sM[g]);
    end
    9'b00010100?: begin
        logic [31:0] src, d;
        d = op[31:0];
        src = c.usrc;
        case (op[39:37])
        3'd0: src = src | d;
        3'd1: src = src & ~d;
        3'd2: src = src ^ d;
        3'd4: if ((src & d) == d) astat_upd(c, 32'h0, BTF); else astat_upd(c, BTF, 32'h0);
        3'd5: if (src == d) astat_upd(c, 32'h0, BTF); else astat_upd(c, BTF, 32'h0);
        default: ;
        endcase
        set_ureg(c, {4'h7, op[35:32]}, src);        // MAME writes back whatever the operation, after BTF
    end
    9'b000101100: begin c.pmr[op[38]] = 1'b1; c.pmi[op[38]] = op[34:32]; c.pmm[op[38]] = op[31:0]; c.pms[op[38]] = x_sX[op[38]]; end
    9'b00010111?: begin
        c.r_push_loop = op[39]; c.r_pop_loop = op[38];
        c.r_push_status = op[37]; c.r_pop_status = op[36];
        c.r_push_pc = op[35]; c.r_pop_pc = op[34];
    end
    9'b000000000: ;
    9'b000000001: begin
        c.s.daddr = hv_pc; c.s.faddr = hv_pc + 1; c.s.nfaddr = hv_pc + 2;
        c.s.idle = 1'b1;
    end
    default: ;
    endcase
endtask
