// SPDX-License-Identifier: GPL-3.0-or-later
//
// Float multiply in two stages, bit-exact to sharc_fp_pkg::f_mul (the multiplier flushes
// neither operands nor result), or with MAME_RND 0 to man_mul. Stage 1 registers at `en`; the
// result and flags are stage 2's, combinational, in the clock after.
//
// MAME_RND 1. Fast path: normal (or zero, infinite, NaN) operands whose product cannot
// underflow: one DSP product (stage 1), a one-bit normalise and the rounding (stage 2). Slow
// path: a denormal operand, or an exponent sum small enough that the result may be denormal:
// `busy` holds the pipeline (en low) for four clocks while the product is normalised,
// multiplied, shifted to the denormal boundary and rounded in steps; the result then enters
// stage 2 with the next en.
//
// MAME_RND 0 (the manual, sharc_fp_pkg::man_mul): operands flushed, so there is only the fast
// path and `busy` is 0. With `rnd32`: toward zero under `trunc`, else to nearest, and a
// post-rounded underflow (exponent unbounded) is a signed zero with MU / MUS (p. 2-16). With
// `rnd32` clear: to nearest, underflow and overflow decided on the exact product, so a round-up
// across 2^128 gives NORM.MAX. An overflow gives NORM.MAX under `trunc`.

module sharc_fmul #(
    parameter bit MAME_RND = 0
) (
    input  logic        clk,
    input  logic        en,             // advance the pipeline
    input  logic        restart,        // new operands: the slow path starts again
    input  logic        valid,          // x, y are a multiply's operands
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic        trunc,          // MODE1.TRUNCATE (MAME_RND 0)
    input  logic        rnd32,          // MODE1.RND32 (MAME_RND 0)
    output logic        busy,           // slow path: keep en low and the operands held
    output logic [31:0] r,
    output logic [31:0] astat,          // MN MV MU MI
    output logic [31:0] stky            // MVS MUS MIS
);

import sharc_fp_pkg::*;

generate if (MAME_RND) begin : g_mame

logic unused_trunc;
assign unused_trunc = trunc ^ rnd32;

// ---------------------------------------------------------------- stage 1

logic        sg, nan1, spec, slow1;
logic [31:0] spec_r;
logic [23:0] ma, mb;
logic [9:0]  esum;
logic [47:0] p;

always_comb begin
    sg = x[31] ^ y[31];
    nan1 = nan_mul(x, y);
    // infinities and zeros give a signed infinity or zero, exactly as ieee_mul's first tests
    spec = is_inf(x) || is_inf(y) || is_zero(x) || is_zero(y);
    spec_r = (is_inf(x) || is_inf(y)) ? {sg, INF[30:0]} : {sg, 31'h0};
    ma = {1'b1, x[22:0]};
    mb = {1'b1, y[22:0]};
    esum = {2'b0, x[30:23]} + {2'b0, y[30:23]};
    // a denormal operand, or a product that may round to a denormal: e = esum - 127 (+1) < 1
    slow1 = valid && !nan1 && !spec && (is_den(x) || is_den(y) || esum <= 10'd128);
    p = ma * mb;
end

// slow path: ieee_mul in four registered steps from the held operands
logic [2:0]  sc;
logic [23:0] qa, qb;
logic signed [11:0] qe;
logic [47:0] qp;
logic [26:0] qs;
logic [31:0] slow_r;

always_ff @(posedge clk) begin
    if (en || restart || !slow1) sc <= 3'd0;
    else if (sc != 3'd4) sc <= sc + 3'd1;
    case (sc)
    3'd0: begin
        logic [4:0]  la, lb;
        logic [23:0] a, b;
        logic signed [11:0] ea, eb;
        a = {x[30:23] != 0, x[22:0]};
        b = {y[30:23] != 0, y[22:0]};
        ea = (x[30:23] == 0) ? 12'sd1 : {4'h0, x[30:23]};
        eb = (y[30:23] == 0) ? 12'sd1 : {4'h0, y[30:23]};
        la = clz24(a); lb = clz24(b);
        qa <= a << la; qb <= b << lb;
        qe <= ea + eb - {7'h0, la} - {7'h0, lb};
    end
    3'd1: qp <= qa * qb;
    3'd2: begin
        logic [47:0] pp;
        logic signed [11:0] e;
        logic [26:0] s;
        if (qp[47]) begin pp = qp; e = qe - 12'sd126; end
        else begin pp = qp << 1; e = qe - 12'sd127; end
        s = {pp[47:22], pp[21:0] != 0};
        if (e < 12'sd1) begin
            logic [11:0] k;
            logic [53:0] wide;
            k = 12'sd1 - e;
            if (k >= 12'd27) s = {26'h0, s != 0};
            else begin
                wide = {s, 27'h0} >> k;
                s = {wide[53:28], wide[27] | (wide[26:0] != 0)};
            end
            e = 12'sd1;
        end
        qs <= s; qe <= e;
    end
    3'd3: slow_r <= round_pack(sg, qe, qs);
    default: ;
    endcase
end

assign busy = slow1 && sc != 3'd4;

logic        v_nan, v_spec, v_slow, v_sg;
logic [31:0] v_r;
logic [47:0] v_p;
logic [9:0]  v_esum;

always_ff @(posedge clk) if (en) begin
    v_nan <= nan1;
    v_spec <= spec;
    v_slow <= slow1;
    v_r <= slow1 ? slow_r : spec_r;
    v_sg <= sg;
    v_p <= p;
    v_esum <= esum;
end

// ---------------------------------------------------------------- stage 2

logic [31:0] res;
always_comb begin
    if (v_spec || v_slow) res = v_r;
    else begin
        logic [26:0] s;
        logic [9:0]  e;
        logic [24:0] m;
        logic        up;
        if (v_p[47]) begin s = {v_p[47:22], v_p[21:0] != 0}; e = v_esum - 10'd126; end
        else         begin s = {v_p[46:21], v_p[20:0] != 0}; e = v_esum - 10'd127; end
        up = s[2] && (s[1] || s[0] || s[3]);
        m = {1'b0, s[26:3]} + {24'h0, up};
        if (m[24]) begin m = m >> 1; e = e + 10'd1; end
        res = (e >= 10'd255) ? {v_sg, INF[30:0]} : {v_sg, e[7:0], m[22:0]};
    end
end

always_comb begin
    if (v_nan) begin r = NAN; astat = MI; stky = MIS; end
    else begin
        r = res;
        astat = (res[31] ? MN : 32'h0) | (is_inf(res) ? MV : 32'h0) | (is_den(res) ? MU : 32'h0);
        stky  = (is_inf(res) ? MVS : 32'h0) | (is_den(res) ? MUS : 32'h0);
    end
end

end else begin : g_man

// ---------------------------------------------------------------- stage 1

logic [31:0] xf, yf;
logic        sg, nan1, inf1, zero1;
logic [47:0] p;
logic [9:0]  esum;

always_comb begin
    xf = flush(x);
    yf = flush(y);
    sg = xf[31] ^ yf[31];
    nan1 = nan_mul(xf, yf);
    inf1 = is_inf(xf) || is_inf(yf);
    zero1 = is_zero(xf) || is_zero(yf);
    p = {1'b1, xf[22:0]} * {1'b1, yf[22:0]};
    esum = {2'b0, xf[30:23]} + {2'b0, yf[30:23]};
end

logic        v_nan, v_inf, v_zero, v_sg, v_trunc, v_rnd32;
logic [47:0] v_p;
logic [9:0]  v_esum;

always_ff @(posedge clk) if (en) begin
    v_nan <= nan1;
    v_inf <= inf1;
    v_zero <= zero1;
    v_sg <= sg;
    v_trunc <= trunc;
    v_rnd32 <= rnd32;
    v_p <= p;
    v_esum <= esum;
end

assign busy = 1'b0;
logic unused_slow;
assign unused_slow = restart ^ valid;

// ---------------------------------------------------------------- stage 2

logic [31:0] res;
logic        ovf, tiny;
always_comb begin
    logic [26:0] s;
    logic signed [11:0] e, ee;
    logic [24:0] m;
    logic        up, nc;
    nc = !v_rnd32;
    if (v_p[47]) begin s = {v_p[47:22], v_p[21:0] != 0}; e = $signed({2'b0, v_esum}) - 12'sd126; end
    else         begin s = {v_p[46:21], v_p[20:0] != 0}; e = $signed({2'b0, v_esum}) - 12'sd127; end
    up = !(v_trunc && v_rnd32) && s[2] && (s[1] || s[0] || s[3]);
    m = {1'b0, s[26:3]} + {24'h0, up};
    ee = e;
    if (m[24]) begin m = m >> 1; ee = e + 12'sd1; end
    ovf  = nc ? e >= 12'sd255 : ee >= 12'sd255;
    tiny = nc ? e < 12'sd1 : ee < 12'sd1;
    if (ovf)                 res = {v_sg, v_trunc ? MAXF[30:0] : INF[30:0]};
    else if (tiny)           res = {v_sg, 31'h0};
    else if (ee >= 12'sd255) res = {v_sg, MAXF[30:0]};
    else                     res = {v_sg, ee[7:0], m[22:0]};
end

always_comb begin
    if (v_nan) begin r = NAN; astat = MI; stky = MIS; end
    else if (v_inf) begin r = {v_sg, INF[30:0]}; astat = MV | (v_sg ? MN : 32'h0); stky = MVS; end
    else if (v_zero) begin r = {v_sg, 31'h0}; astat = v_sg ? MN : 32'h0; stky = '0; end
    else begin
        r = res;
        astat = (v_sg ? MN : 32'h0) | (ovf ? MV : 32'h0) | (tiny ? MU : 32'h0);
        stky  = (ovf ? MVS : 32'h0) | (tiny ? MUS : 32'h0);
    end
end

end endgenerate

endmodule
