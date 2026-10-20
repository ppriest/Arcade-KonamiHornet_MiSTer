#!/usr/bin/env python3
"""Generates rtl/synth_fp: each sharc_fp_pkg function in its own registered module, for
per-function area and slack (docs/SHARC_V2.md). Then: cd rtl/synth_fp; quartus_sh --flow compile fp;
quartus_sta -t slack_per_fn.tcl."""
from pathlib import Path
R = Path("E:/Arcade-KonamiHornet_MiSTer/rtl/synth_fp")
R.mkdir(exist_ok=True)
fns = {
    "f_add":    "f_add(x, y, t)",
    "f_sub":    "f_sub(x, y, t)",
    "f_avg":    "f_avg(x, y, t)",
    "f_mul":    "f_mul(x, y)",
    "f_fix":    "f_fix(x, t, y, t, 1'b0)",
    "f_float":  "f_float(x, t, y, 1'b0)",
    "f_recips": "f_recips(x)",
    "f_rsqrts": "f_rsqrts(x)",
    "f_comp":   "f_comp(x, y, 32'h0)",
    "f_minmax": "f_minmax(x, y, t)",
    "f_logb":   "f_logb(x)",
    "f_scalb":  "f_scalb(x, y)",
    "f_clip":   "f_clip(x, y)",
}
mods = []
for n, call in fns.items():
    mods.append(f"""module m_{n} (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fres_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= {call}; o <= r.r ^ r.astat ^ r.stky; end
endmodule
""")
mods.append("""module m_f_addsub (input logic clk, input logic [31:0] xi, yi, input logic ti, output logic [31:0] o);
    import sharc_fp_pkg::*;
    logic [31:0] x, y; logic t; fdual_t r;
    always_ff @(posedge clk) begin x <= xi; y <= yi; t <= ti; r <= f_addsub(x, y, t); o <= r.add ^ r.sub ^ r.astat ^ r.stky; end
endmodule
""")
names = list(fns) + ["f_addsub"]
top = ["module fp_top (input logic clk, input logic din, output logic dout);",
       "    logic [127:0] l;",
       "    always_ff @(posedge clk) l <= {l[126:0], din ^ l[127] ^ l[125] ^ l[100] ^ l[98]};",
       f"    logic [31:0] o [{len(names)}];"]
for k, n in enumerate(names):
    top.append(f"    m_{n} u_{n} (.clk, .xi(l[31:0] ^ {{{k+1}{{1'b1}}}}), .yi(l[63:32]), .ti(l[64 + {k}]), .o(o[{k}]));")
top.append("    always_ff @(posedge clk) begin logic [31:0] a; a = '0; for (int i = 0; i < %d; i++) a = a ^ o[i]; dout <= ^a; end" % len(names))
top.append("endmodule")
(R / "fp_top.sv").write_text("// generated: each SHARC FP function as its own module, for per-function area and timing\n" + "".join(mods) + "\n".join(top) + "\n")
(R / "fp.qsf").write_text("""set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY fp_top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL
set_global_assignment -name SYSTEMVERILOG_FILE ../cpu/sharc/sharc_fp_pkg.sv
set_global_assignment -name SYSTEMVERILOG_FILE fp_top.sv
set_global_assignment -name SDC_FILE fp.sdc
""")
(R / "fp.qpf").write_text('PROJECT_REVISION = "fp"\n')
(R / "fp.sdc").write_text("create_clock -name clk -period 15.625 [get_ports clk]\nderive_clock_uncertainty\nset_false_path -from [get_ports din] -to *\nset_false_path -from * -to [get_ports dout]\n")
(R / ".gitignore").write_text("db/\nincremental_db/\noutput_files/\n*.log\n")
print("ok", len(names))
