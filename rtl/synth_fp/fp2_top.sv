// the v2 float units with registered operands from an LFSR, for area and slack
module fp2_top (input logic clk, input logic din, output logic dout);
    logic [127:0] l;
    always_ff @(posedge clk) l <= {l[126:0], din ^ l[127] ^ l[125] ^ l[100] ^ l[98]};
    logic [31:0] x, y, r, a, s;
    logic sub, trunc;
    always_ff @(posedge clk) begin x <= l[31:0]; y <= l[63:32]; sub <= l[64]; trunc <= l[65]; end
    sharc_fadd u_fadd (.clk, .en(l[66]), .x, .y, .sub, .trunc, .r, .astat(a), .stky(s));
    logic [31:0] mr, ma, ms;
    logic busy;
    sharc_fmul u_fmul (.clk, .en(l[66] & !busy), .restart(1'b0), .valid(l[67]), .x, .y, .busy, .r(mr), .astat(ma), .stky(ms));
    always_ff @(posedge clk) dout <= ^{r, a, s, mr, ma, ms};
endmodule
