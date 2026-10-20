// generated: each SHARC FP function as its own module, for per-function area and timing
module m_f_add (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_add(x, y, t); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_sub (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_sub(x, y, t); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_avg (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_avg(x, y, t); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_mul (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_mul(x, y); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_fix (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_fix(x, t, y, t, 1'b0); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_float (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_float(x, t, y, 1'b0); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_recips (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_recips(x); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_rsqrts (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_rsqrts(x); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_comp (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_comp(x, y, 32'h0); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_minmax (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_minmax(x, y, t); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_logb (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_logb(x); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_scalb (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_scalb(x, y); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_clip (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_clip(x, y); o <= r.r ^ r.astat ^ r.stky; end
endmodule
module m_f_addsub (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fdual_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_addsub(x, y, t); o <= r.add ^ r.sub ^ r.astat ^ r.stky; end
endmodule
module fp_top (input logic clk, input logic din, output logic dout);
    logic [127:0] l;
    always_ff @(posedge clk) l <= {l[126:0], din ^ l[127] ^ l[125] ^ l[100] ^ l[98]};
    logic [31:0] o [14];
    m_f_add u_f_add (.clk, .xi(l[31:0] ^ {1{1'b1}}), .yi(l[63:32]), .ti(l[64 + 0]), .o(o[0]));
    m_f_sub u_f_sub (.clk, .xi(l[31:0] ^ {2{1'b1}}), .yi(l[63:32]), .ti(l[64 + 1]), .o(o[1]));
    m_f_avg u_f_avg (.clk, .xi(l[31:0] ^ {3{1'b1}}), .yi(l[63:32]), .ti(l[64 + 2]), .o(o[2]));
    m_f_mul u_f_mul (.clk, .xi(l[31:0] ^ {4{1'b1}}), .yi(l[63:32]), .ti(l[64 + 3]), .o(o[3]));
    m_f_fix u_f_fix (.clk, .xi(l[31:0] ^ {5{1'b1}}), .yi(l[63:32]), .ti(l[64 + 4]), .o(o[4]));
    m_f_float u_f_float (.clk, .xi(l[31:0] ^ {6{1'b1}}), .yi(l[63:32]), .ti(l[64 + 5]), .o(o[5]));
    m_f_recips u_f_recips (.clk, .xi(l[31:0] ^ {7{1'b1}}), .yi(l[63:32]), .ti(l[64 + 6]), .o(o[6]));
    m_f_rsqrts u_f_rsqrts (.clk, .xi(l[31:0] ^ {8{1'b1}}), .yi(l[63:32]), .ti(l[64 + 7]), .o(o[7]));
    m_f_comp u_f_comp (.clk, .xi(l[31:0] ^ {9{1'b1}}), .yi(l[63:32]), .ti(l[64 + 8]), .o(o[8]));
    m_f_minmax u_f_minmax (.clk, .xi(l[31:0] ^ {10{1'b1}}), .yi(l[63:32]), .ti(l[64 + 9]), .o(o[9]));
    m_f_logb u_f_logb (.clk, .xi(l[31:0] ^ {11{1'b1}}), .yi(l[63:32]), .ti(l[64 + 10]), .o(o[10]));
    m_f_scalb u_f_scalb (.clk, .xi(l[31:0] ^ {12{1'b1}}), .yi(l[63:32]), .ti(l[64 + 11]), .o(o[11]));
    m_f_clip u_f_clip (.clk, .xi(l[31:0] ^ {13{1'b1}}), .yi(l[63:32]), .ti(l[64 + 12]), .o(o[12]));
    m_f_addsub u_f_addsub (.clk, .xi(l[31:0] ^ {14{1'b1}}), .yi(l[63:32]), .ti(l[64 + 13]), .o(o[13]));
    always_ff @(posedge clk) begin logic [31:0] a; a = '0; for (int i = 0; i < 14; i++) a = a ^ o[i]; dout <= ^a; end
endmodule
