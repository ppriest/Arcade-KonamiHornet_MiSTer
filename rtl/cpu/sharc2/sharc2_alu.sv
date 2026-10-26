// SPDX-License-Identifier: GPL-3.0-or-later
//
// SHARC v2 compute: every unit of the compute field and the immediate shifts, placed in the
// pipeline's X and W clocks.
//
//   X (one clock): fixed ALU, shifter, MR moves and clears; results and flags this clock.
//   W (the clock after X): float adders (sharc_fadd x2), float multiplier (sharc_fmul), fixed
//     multiplier, the slow unit (FLOAT, FIX, RECIPS, RSQRTS, MIN, MAX, CLIP, COMP, ...: v1's
//     sharc_fp_pkg functions, a two-clock multicycle path from mc_* loaded as the op enters X)
//     and FAVG (four clocks from avg_*, X held two clocks more).
//
// The core applies X's flag updates at the X edge and W's at the W edge, W's first: W holds the
// older instruction.

module sharc2_alu #(
    parameter bit SUBSET = 0,          // the game's subset of the compute operations (sharc2_pkg comp_unsup)
    parameter bit ONE_FADD = 0         // the dual forms' subtract through adder 0 too: X held a clock more
) (
    input  logic        clk,
    input  logic        ce,

    // D: the instruction entering X at this edge (d_go), with its adder operands
    input  logic        d_go,
    input  logic        d_comp_on,
    input  logic [22:0] d_comp,
    input  logic [31:0] d_ax, d_ay,
    output logic        d_mc_wait,      // D's op needs the slow unit while it is busy

    // X
    input  logic        x_go,           // X completes at this edge
    input  logic        x_drop,         // X's instruction is squashed at this edge
    input  logic        x_exec,         // X's compute executes (form, condition)
    input  logic        x_comp_on,
    input  logic [22:0] x_comp,
    input  logic        x_shimm,        // immediate shift (sharcop_shift_imm forms)
    input  logic [5:0]  x_shimm_op,
    input  logic [11:0] x_shimm_data,
    input  logic [3:0]  x_shimm_rn,
    input  logic [31:0] ax, ay, mx, my, xe,
    input  logic [31:0] astat_in,       // before this instruction; valid when needs_astat
    input  logic        trunc, alusat,
    input  logic [63:0] mrf, mrb,
    output logic        x_busy,
    output logic        x_needs_astat,
    output logic [1:0]  xw_we,
    output logic [1:0]  xw_wr,          // xw_we before x_exec: the registers X's compute names
    output logic [3:0]  xw_r0, xw_r1,
    output logic [31:0] xw_d0, xw_d1,
    output logic [31:0] x_aclr, x_aset, x_sset,
    output logic        x_mrf_we, x_mrb_we,
    output logic [63:0] x_mr_d,

    // W
    output logic        w_on,           // W holds an executed compute with late parts
    output logic [2:0]  ww_we,          // Rm, Ra, Rs; later ports win on the same register
    output logic [3:0]  ww_r0, ww_r1, ww_r2,
    output logic [31:0] ww_d0, ww_d1, ww_d2,
    output logic [31:0] w_aclr, w_aset, w_sset
);

import sharc_fp_pkg::*;
import sharc2_pkg::*;

cinfo_t xi, di;
assign xi = x_comp_on ? comp_info(x_comp, SUBSET) : '0;
assign di = d_comp_on ? comp_info(d_comp, SUBSET) : '0;
assign x_needs_astat = x_exec && xi.needs_astat;

// ---------------------------------------------------------------- X: one-clock units

always_comb begin
    xres_t o, sh;
    logic [7:0] op;
    logic [5:0] mop;
    o = '0;
    op = x_comp[19:12];
    mop = x_comp[21:16];
    x_mrf_we = 1'b0; x_mrb_we = 1'b0; x_mr_d = 64'h0;
    // one shifter for the immediate and the compute-field forms
    sh = shifter(x_shimm ? x_shimm_op : op[7:2], x_shimm ? {20'h0, x_shimm_data} : ay, x_shimm,
                 x_shimm ? x_shimm_rn : x_comp[11:8], ax, xe, SUBSET);
    // the result whether or not it executes: x_exec is late (condition, handler) and gates only
    // the enables, so that the register numbers do not wait for it
    if (x_shimm)
        o = sh;
    else if (x_comp_on && xi.x) begin
        if (!x_comp[22]) begin
            case (x_comp[21:20])
            2'd0: if (op >= 8'h70 && op <= 8'h7f) o = alu_dual(x_comp[11:8], x_comp[15:12], ax, ay, alusat);
                  else o = alu_fixed(op, x_comp[11:8], ax, ay, astat_in, alusat, SUBSET);
            2'd1: if (op == 8'h14) x_mrf_we = 1'b1; else x_mrb_we = 1'b1;
            default: o = sh;
            endcase
        end else case (mop)
        6'h00: if (!SUBSET) begin
            o.we0 = 1'b1; o.r0 = x_comp[11:8];
            case (op[3:0])
            4'd0: o.d0 = mrf[31:0];
            4'd1: o.d0 = mrf[63:32];
            4'd4: o.d0 = mrb[31:0];
            default: o.d0 = mrb[63:32];
            endcase
            o.aclr = MUL_FLAGS;
        end
        6'h01: begin
            case (op[3:0])
            4'd0: begin x_mrf_we = 1'b1; x_mr_d = {mrf[63:32], xe}; end
            4'd1: begin x_mrf_we = 1'b1; x_mr_d = {xe, mrf[31:0]}; end
            4'd4: begin x_mrb_we = 1'b1; x_mr_d = {mrb[63:32], xe}; end
            default: begin x_mrb_we = 1'b1; x_mr_d = {xe, mrb[31:0]}; end
            endcase
            o.aclr = MUL_FLAGS;
        end
        default: if (!SUBSET) o = alu_mf(x_comp[11:8], mop == 6'h05, ax, ay);    // 04, 05
        endcase
    end
    xw_we = x_exec ? {o.we1, o.we0} : 2'b00;
    xw_wr = {o.we1, o.we0};
    xw_r0 = o.r0; xw_r1 = o.r1; xw_d0 = o.d0; xw_d1 = o.d1;
    x_aclr = x_exec ? o.aclr : 32'h0; x_aset = x_exec ? o.aset : 32'h0; x_sset = x_exec ? o.sset : 32'h0;
    if (!x_exec) begin x_mrf_we = 1'b0; x_mrb_we = 1'b0; end
end

// ---------------------------------------------------------------- stage 1 of the late units

logic [31:0] fa0_r, fa0_a, fa0_s, fa1_r, fa1_a, fa1_s, fm_r, fm_a, fm_s;
logic        fa0_nan, fa0_infb, fm_busy;
// ONE_FADD: a dual form's first X clock holds X and loads adder 0 with the subtract (fa0_first);
// its result, on adder 0's output while X waits, is kept as adder 1's (fs_*); the add follows at x_go
logic        x_dl, dual_n, fa0_first;
assign fa0_first = ONE_FADD && x_dl && !dual_n;

sharc_fadd u_fadd0 (.clk, .en(ce && (x_go || fa0_first)), .x(ax), .y(ay), .sub(fa0_first || xi.sub), .trunc,
                    .r(fa0_r), .astat(fa0_a), .stky(fa0_s), .nan_in(fa0_nan), .inf_both(fa0_infb));
generate if (ONE_FADD) begin : g_one_fadd
    always_ff @(posedge clk) if (ce && x_dl && dual_n) begin fa1_r <= fa0_r; fa1_a <= fa0_a; fa1_s <= fa0_s; end
end else begin : g_two_fadd
    sharc_fadd u_fadd1 (.clk, .en(ce && x_go), .x(ax), .y(ay), .sub(1'b1), .trunc,
                        .r(fa1_r), .astat(fa1_a), .stky(fa1_s), .nan_in(), .inf_both());
end endgenerate
sharc_fmul u_fmul (.clk, .en(ce && x_go), .restart(ce && (d_go || x_drop)), .valid(xi.fmul), .x(mx), .y(my), .busy(fm_busy),
                   .r(fm_r), .astat(fm_a), .stky(fm_s));

// fixed multiplier: the product in X, the accumulate and flags in W
logic [63:0] im_p;
logic        im_signed;
assign im_signed = x_comp[22] || x_comp[19:12] != 8'h40;
always_ff @(posedge clk) if (ce && x_go)
    im_p <= 64'($signed({im_signed & mx[31], mx}) * $signed({im_signed & my[31], my}));

// the slow unit's operands, loaded as its op enters X and read until the end of its W clock: a
// second op waits while the first is in X
// preserve: physical synthesis must not retime them, or a retimed register's name escapes the SDC's
// multicycle on mc_* and avg_* (build 74bb49a: by_OTERM, clk_dsp -0.632 ns timed in one clock)
(* preserve *) logic [31:0] mc_x, mc_y, avg_x, avg_y;
(* preserve *) mc_t         mc_op;
logic        x_mc, w_mc, x_avg, w_avg;
always_ff @(posedge clk) if (ce && d_go) begin
    if (di.mc) begin mc_x <= d_ax; mc_y <= d_ay; mc_op <= di.mc_op; end
    if (di.avg) begin avg_x <= d_ax; avg_y <= d_ay; end
end
assign d_mc_wait = (di.mc && x_mc) || (di.avg && x_avg);

// FAVG holds X until its four clocks from avg_* are up. The holds do not wait for the condition
// (the core's timing): a FAVG or slow-path multiply that does not execute holds X too
logic [1:0] avg_n;
always_ff @(posedge clk) if (ce) avg_n <= (x_go || !x_avg) ? 2'd0 : (avg_n == 2'd3 ? avg_n : avg_n + 2'd1);
always_ff @(posedge clk) if (ce) dual_n <= !(x_go || x_drop || !x_dl);
assign x_busy = fm_busy || (x_avg && avg_n < 2'd2) || fa0_first;

// ---------------------------------------------------------------- W

cinfo_t      wi;
logic        w_exec, w_trunc, w_xsign, w_ysign;
logic [7:0]  w_top;                    // ASTAT[31:24] before the op (COMP's history)
logic [5:0]  w_mop;
logic [7:0]  w_op;
logic        w_mf;
logic [63:0] w_mr;                     // the accumulator an MRF/MRB += op adds

always_ff @(posedge clk) if (ce) begin
    if (x_go) begin
        wi <= xi;
        w_exec <= x_exec && x_comp_on;
        w_trunc <= trunc;
        w_xsign <= ax[31]; w_ysign <= ay[31];
        w_top <= astat_in[31:24];
        w_mop <= x_comp[21:16];
        w_op <= x_comp[19:12];
        w_mf <= x_comp[22];
        x_mc <= 1'b0; x_avg <= 1'b0; x_dl <= 1'b0;
        w_mc <= xi.mc; w_avg <= xi.avg;
    end else begin
        w_exec <= 1'b0;
        w_mc <= 1'b0; w_avg <= 1'b0;
    end
    if (x_drop) begin x_mc <= 1'b0; x_avg <= 1'b0; x_dl <= 1'b0; end
    if (d_go) begin x_mc <= di.mc; x_avg <= di.avg; x_dl <= ONE_FADD && di.dual; end
end

// the slow unit: sharc_fp_pkg on mc_* (multicycle 2), FAVG on avg_* (multicycle 4)
fres_t mc_o, avg_o;
// one instance of each function, its variant's arguments chosen by the op
always_comb begin
    logic        by, mf;
    fres_t       fix_o, float_o;
    by = mc_op == MC_FIXBY || mc_op == MC_FLOATBY || mc_op == MC_FLOAT_MF || mc_op == MC_FIX_MF;
    mf = mc_op == MC_FLOAT_MF || mc_op == MC_FIX_MF;
    fix_o = f_fix(mc_x, by, by ? mc_y : 32'h0, w_trunc, mf);
    float_o = f_float(mc_x, by, by ? mc_y : 32'h0, mf);
    case (mc_op)
    MC_PASS:     mc_o = f_pass(mc_x);
    MC_NEG:      mc_o = f_neg(mc_x);
    MC_ABS:      mc_o = f_abs(mc_x);
    MC_SCALB:    mc_o = f_scalb(mc_x, mc_y);
    MC_LOGB:     mc_o = f_logb(mc_x);
    MC_RECIPS:   mc_o = f_recips(mc_x);
    MC_RSQRTS:   mc_o = f_rsqrts(mc_x);
    MC_FIX, MC_FIXBY: mc_o = fix_o;
    MC_FLOAT, MC_FLOATBY, MC_FLOAT_MF: mc_o = float_o;
    MC_COPYSIGN: mc_o = f_copysign(mc_x, mc_y);
    MC_MIN, MC_MAX: mc_o = f_minmax(mc_x, mc_y, mc_op == MC_MAX);
    MC_CLIP:     mc_o = f_clip(mc_x, mc_y);
    MC_COMP:     mc_o = f_comp(mc_x, mc_y, 32'h0);          // history byte added in W
    default:     mc_o = fix_o;                              // MC_FIX_MF
    endcase
    avg_o = SUBSET ? '0 : f_avg(avg_x, avg_y, w_trunc);
end

// FADD_FSUB's two infinite operands: MAME stores the integer pattern converted (compute.hxx:386)
localparam logic [31:0] INF_PAT_P = 32'h4EFF_0000;   // i2f_u(0x7F800000) = i2f_u(0x7F7FFFFF)
localparam logic [31:0] INF_PAT_N = 32'h4F7F_8000;   // i2f_u(0xFF800000) = i2f_u(0xFF7FFFFF)

always_comb begin
    fres_t a;                          // adder / slow-unit port
    logic [31:0] sub_r;
    logic [31:0] m_r, m_a, m_s;
    logic [63:0] p;
    a = '0; sub_r = 32'h0; m_r = 32'h0; m_a = 32'h0; m_s = 32'h0;

    // multiplier port
    if (wi.fmul) begin m_r = fm_r; m_a = fm_a; m_s = fm_s; end
    else if (wi.imul) begin
        if (w_mf) begin
            // SSFR: Rm = (Rxm * Rym) >> 31
            m_r = im_p[62:31];
            m_a = m_r[31] ? MN : 32'h0;
        end else begin
            p = im_p;
            if (w_op == 8'hb0) p = p + w_mr;
            else if (w_op == 8'hb2) p = p + w_mr;
            m_r = p[31:0];
            if (p[31]) m_a |= MN;
            if (p[63:32] != 0 && p[63:32] != 32'hFFFF_FFFF) m_a |= MV;
            if (p[63:32] == 0 && p[31:0] != 0) m_a |= MU;
        end
    end

    // adder / slow-unit port
    if (wi.dual) begin
        if (fa0_nan) begin
            a.r = NAN; sub_r = NAN; a.astat = AI | AF; a.stky = AIS;
        end else if (!fa0_infb) begin
            a.r = fa0_r; sub_r = fa1_r;
            a.astat = ((fa0_a | fa1_a) & ~AN) | (((fa0_r | fa1_r) & SIGN) ? AN : 32'h0) | AF;
            a.stky = fa0_s | fa1_s;
        end else begin
            logic [31:0] pat;
            pat = w_xsign ? INF_PAT_N : INF_PAT_P;
            if (w_xsign ^ w_ysign) begin a.r = NAN; sub_r = pat; end
            else begin a.r = pat; sub_r = NAN; end
            a.astat = (w_xsign ? AN : 32'h0) | AV | AI | AF;
            a.stky = AVS | AIS;
        end
    end else if (wi.fadd) begin
        a.r = fa0_r; a.astat = fa0_a; a.stky = fa0_s;
        if (wi.absr) begin
            if ((a.astat & AI) == 0) a.r = a.r & ~SIGN;
            a.astat = a.astat & ~AN;
        end
    end else if (wi.avg) a = avg_o;
    else if (wi.mc) begin
        a = mc_o;
        if (wi.mc_op == MC_COMP) begin
            logic [31:0] acc;
            acc = ({w_top, 24'h0} >> 1) & 32'h7F00_0000;
            if ((mc_o.astat & (AZ | AN)) == 0) acc |= 32'h8000_0000;
            a.astat = a.astat | acc;
        end
    end

    w_on = w_exec && wi.w_flags;
    ww_we = w_exec ? {wi.ws_en, wi.wa_en, wi.wm_en} : 3'b000;
    ww_r0 = wi.wm; ww_r1 = wi.wa; ww_r2 = wi.ws;
    ww_d0 = m_r; ww_d1 = a.r; ww_d2 = sub_r;
    w_aclr = w_on ? wi.w_aclr : 32'h0;
    w_aset = w_on ? (m_a | a.astat) : 32'h0;
    w_sset = w_on ? (m_s | a.stky) : 32'h0;
end

// the accumulator for MRF/MRB += Rx * Ry (read in X; MR is only written in X)
always_ff @(posedge clk) if (ce && x_go) w_mr <= (x_comp[19:12] == 8'hb2) ? mrb : mrf;

endmodule
