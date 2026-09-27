// SPDX-License-Identifier: GPL-3.0-or-later
// sharc_fp_pkg alone, one operation per evaluation; main.cpp compares with MAME's code.
module tb_sharcfp (
    input  logic        clk,
    input  logic [4:0]  op,
    input  logic [31:0] x, y, astat_in,
    input  logic        trunc,
    output logic [31:0] r, r2, astat, stky
);
    import sharc_fp_pkg::*;
    fres_t  o;
    fdual_t d;
    always_comb begin
        o = '0; d = '0; r2 = 32'h0;
        case (op)
        5'd0:  o = f_add(x, y, trunc);
        5'd1:  o = f_sub(x, y, trunc);
        5'd2:  o = f_avg(x, y, trunc);
        5'd3:  begin d = f_addsub(x, y, trunc); o.r = d.add; o.astat = d.astat; o.stky = d.stky; r2 = d.sub; end
        5'd4:  o = f_abs(x);
        5'd5:  o = f_minmax(x, y, 1'b0);
        5'd6:  o = f_minmax(x, y, 1'b1);
        5'd7:  o = f_neg(x);
        5'd8:  o = f_pass(x);
        5'd9:  o = f_comp(x, y, astat_in);
        5'd10: o = f_scalb(x, y);
        5'd11: o = f_logb(x);
        5'd12: o = f_fix(x, 1'b0, y, trunc, 1'b0);
        5'd13: o = f_fix(x, 1'b1, y, trunc, 1'b0);
        5'd14: o = f_fix(x, 1'b1, y, trunc, 1'b1);
        5'd15: o = f_float(x, 1'b0, y, 1'b0);
        5'd16: o = f_float(x, 1'b1, y, 1'b0);
        5'd17: o = f_float(x, 1'b1, y, 1'b1);
        5'd18: o = f_recips(x);
        5'd19: o = f_rsqrts(x);
        5'd20: o = f_copysign(x, y);
        5'd21: o = f_clip(x, y);
        5'd22: o = f_mul(x, y);
        default: ;
        endcase
        r = o.r; astat = o.astat; stky = o.stky;
    end
endmodule
