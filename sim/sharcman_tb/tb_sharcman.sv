// SPDX-License-Identifier: GPL-3.0-or-later
// The manual's float operations (MAME_RND 0): sharc_fp_pkg's man_* functions, combinational, and
// the v2 units, whose results are out after the clock edge that takes the operands; main.cpp
// compares both with its own reference.
module tb_sharcman (
    input  logic        clk,
    input  logic [4:0]  op,
    input  logic [31:0] x, y, astat_in,
    input  logic        trunc, rnd32, alusat,
    output logic [31:0] r, r2, astat, stky,
    output logic [31:0] ar, aa, as, mr, ma, ms,
    output logic        busy
);
    import sharc_fp_pkg::*;
    fres_t  o;
    fdual_t d;
    always_comb begin
        o = '0; d = '0; r2 = 32'h0;
        case (op)
        5'd0:  o = man_add(x, y, trunc, rnd32);
        5'd1:  o = man_sub(x, y, trunc, rnd32);
        5'd2:  o = man_avg(x, y, trunc, rnd32);
        5'd3:  begin d = man_addsub(x, y, trunc, rnd32); o.r = d.add; o.astat = d.astat; o.stky = d.stky; r2 = d.sub; end
        5'd4:  o = man_mul(x, y, trunc, rnd32);
        5'd5:  o = man_fix(x, 1'b0, 32'h0, trunc, alusat);
        5'd6:  o = man_fix(x, 1'b1, y, trunc, alusat);    // FIX BY, single and multifunction forms
        5'd7:  o = man_float(x, 1'b0, 32'h0, trunc, rnd32);
        5'd8:  o = man_float(x, 1'b1, y, trunc, rnd32);   // FLOAT BY, both forms
        5'd9:  o = man_comp(x, y, astat_in);
        5'd10: o = man_minmax(x, y, 1'b0);
        5'd11: o = man_minmax(x, y, 1'b1);
        5'd12: o = man_scalb(x, y, trunc);
        5'd13: o = man_logb(x, alusat);
        5'd14: o = man_recips(x);
        5'd15: o = man_rsqrts(x);
        5'd16: o = f_abs(x);                             // MAME's, which the manual agrees with
        5'd17: o = f_pass(x);
        5'd18: o = f_neg(x);
        5'd19: o = f_copysign(x, y);
        5'd20: o = f_clip(x, y);
        default: ;
        endcase
        r = o.r; astat = o.astat; stky = o.stky;
    end
    sharc_fadd #(.MAME_RND(0)) u_add (.clk, .en(1'b1), .x, .y, .sub(op == 5'd1), .trunc, .rnd32,
                                      .r(ar), .astat(aa), .stky(as), .nan_in(), .inf_both());
    sharc_fmul #(.MAME_RND(0)) u_mul (.clk, .en(1'b1), .restart(1'b0), .valid(1'b1), .x, .y, .trunc, .rnd32,
                                      .busy, .r(mr), .astat(ma), .stky(ms));
endmodule
