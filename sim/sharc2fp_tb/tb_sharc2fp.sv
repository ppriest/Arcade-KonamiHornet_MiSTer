// SPDX-License-Identifier: GPL-3.0-or-later
// The v2 float units against sharc_fp_pkg: operands every advancing clock, the package's
// results delayed to match the units' latency. main.cpp drives en = !busy and counts `bad`.
module tb_sharc2fp (
    input  logic        clk,
    input  logic        en,
    input  logic [31:0] x, y,
    input  logic        sub, trunc,
    output logic        busy,
    output logic        bad_add, bad_mul,
    output logic [31:0] got, want
);
    import sharc_fp_pkg::*;
    logic [31:0] ar, aa, as, mr, ma, ms;
    sharc_fadd u_add (.clk, .en, .x, .y, .sub, .trunc, .r(ar), .astat(aa), .stky(as), .nan_in(), .inf_both());
    sharc_fmul u_mul (.clk, .en, .restart(1'b0), .valid(1'b1), .x, .y, .busy, .r(mr), .astat(ma), .stky(ms));
    fres_t a2, m2;
    always_ff @(posedge clk) if (en) begin
        a2 <= sub ? f_sub(x, y, trunc) : f_add(x, y, trunc);
        m2 <= f_mul(x, y);
    end
    assign bad_add = {ar, aa, as} != {a2.r, a2.astat, a2.stky};
    assign bad_mul = {mr, ma, ms} != {m2.r, m2.astat, m2.stky};
    assign got  = bad_add ? ar : mr;
    assign want = bad_add ? a2.r : m2.r;
endmodule
