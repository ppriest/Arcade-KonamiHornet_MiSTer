#!/usr/bin/env python3
"""Where sharc2_core's logic goes: synthesise (quartus_map only) copies of the core with one part
removed each, and print the core's combinational ALUTs, its own and the ALU's. Run in rtl/synth_sharc.

    python area_exp.py [-j 4] [name ...]

Each variant builds in x_<name>/ (gitignored). quartus_map blocks every session's JTAG
(scripts/hwlock.py): each run checks that no JTAG session holds or waits for the Blaster.
"""
import argparse
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "cpu/sharc2"
BOARD = HERE.parent / "board"
REPO = HERE.parent.parent
FILES = {"core": "sharc2_core.sv", "ops": "sharc2_ops.svh", "alu": "sharc2_alu.sv", "pkg": "sharc2_pkg.sv"}

DEAD = "if (1'b0) "      # a prefix that removes the statement after it

# name -> list of (file, old, new): the knockouts, each a measurement, not a design
VARIANTS = {
    "base": [],
    "no_step": [("core", "            case (k0)\n            4'(OP_CLEARINT)", "            case (4'd14)\n            4'(OP_CLEARINT)")],
    "no_dmae": [("core", "assign e_start = !e_busy && run && !booting &&", "assign e_start = 1'b0 && !e_busy && run && !booting &&")],
    "no_loopend": [("core", "                if (le) op_loopend(c);\n", "")],
    "no_fuse": [("core", "                if (fz && ok) begin", "                if (1'b0) begin")],
    "no_iopw": [("core", "            iop_write(c, a.addr[7:0], a.wdata[31:0]);", "")],
    "no_getureg": [("core", "        c.usrc = get_ureg(c, usrc_sel(x_op));", "        c.usrc = 32'h0;")],
    # the DMA registers at the chip's widths: C, EC 16 bits, II 17, CP 18, GP none
    "narrow": [("ops", "    8'h40: n.dma_int_index[0] = d;", "    8'h40: n.dma_int_index[0] = d & 32'h1FFFF;"),
               ("ops", "    8'h42: n.dma_int_count[0] = d;", "    8'h42: n.dma_int_count[0] = d & 32'hFFFF;"),
               ("ops", "    8'h43: n.dma_chain_ptr[0] = d;", "    8'h43: n.dma_chain_ptr[0] = d & 32'h3FFFF;"),
               ("ops", "    8'h44: n.dma_gen[0] = d;", ""),
               ("ops", "    8'h47: n.dma_ext_count[0] = d;", "    8'h47: n.dma_ext_count[0] = d & 32'hFFFF;"),
               ("ops", "    8'h48: n.dma_int_index[1] = d;", "    8'h48: n.dma_int_index[1] = d & 32'h1FFFF;"),
               ("ops", "    8'h4a: n.dma_int_count[1] = d;", "    8'h4a: n.dma_int_count[1] = d & 32'hFFFF;"),
               ("ops", "    8'h4b: n.dma_chain_ptr[1] = d;", "    8'h4b: n.dma_chain_ptr[1] = d & 32'h3FFFF;"),
               ("ops", "    8'h4c: n.dma_gen[1] = d;", ""),
               ("ops", "    8'h4f: n.dma_ext_count[1] = d;", "    8'h4f: n.dma_ext_count[1] = d & 32'hFFFF;")],
    # step 1: the compute units gradius4's program never uses (HARDWARE_NOTES, "Program census")
    "k_favg": [("alu", "    avg_o = f_avg(avg_x, avg_y, w_trunc);", "    avg_o = '0;")],
    "k_mcops": [("alu", "    MC_COPYSIGN: mc_o = f_copysign(mc_x, mc_y);\n", ""),
                ("alu", "    MC_CLIP:     mc_o = f_clip(mc_x, mc_y);\n", "")],
    "k_alufix": [("pkg", "    8'h01, 8'h05, 8'h25, 8'h29: begin", "    8'h01, 8'h29: begin"),
                 ("pkg", "    8'h02, 8'h06, 8'h26, 8'h2a: begin", "    8'h02, 8'h2a: begin"),
                 ("pkg", "    8'h30: begin\n        r = x[31]", "    8'h21: begin\n        r = x[31]"),
                 ("pkg", "    8'h43: r = ~x;\n", ""),
                 ("pkg", "    8'h61: r = ($signed(x) < $signed(y)) ? x : y;\n", ""),
                 ("pkg", "    8'h63: begin\n        logic [31:0] ay;", "    8'h21: begin\n        logic [31:0] ay;")],
    "k_shift": [("pkg", "    6'h01: begin\n        if (sh < 0) begin", "    6'h00: begin\n        if (sh < 0) begin"),
                ("pkg", "    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin", "    6'h10, 6'h12: begin"),
                ("pkg", "    6'h00, 6'h08, 6'h01, 6'h02, 6'h10, 6'h11, 6'h12, 6'h13, 6'h19: if", "    6'h00, 6'h08, 6'h02, 6'h10, 6'h12: if")],
    "k_mf": [("pkg", "        6'h04, 6'h05: begin\n            o.x = 1'b1;", "        6'h00: begin\n            o.x = 1'b1;"),
             ("alu", "        default: o = alu_mf(x_comp[11:8], mop == 6'h05, ax, ay);    // 04, 05", "        default: ;"),
             ("alu", "        6'h00: begin\n            o.we0 = 1'b1; o.r0 = x_comp[11:8];", "        6'h01: begin\n            o.we0 = 1'b1; o.r0 = x_comp[11:8];"),
             ("pkg", "                3'd4: o.avg = 1'b1;\n                3'd5: begin o.mc = 1'b1; o.mc_op = MC_ABS; end\n", "")],
    "k_type1": [("ops", "    9'b001??????: begin\n        logic [3:0]  pmd_r, dmd_r;", "    9'b001??????: " + DEAD + "begin\n        logic [3:0]  pmd_r, dmd_r;"),
                ("core", "x_pb <= pm_q[47:45] == 3'b001;", "x_pb <= 1'b0;")],
    "k_pushpop": [("ops", "        c.r_push_loop = op[39]; c.r_pop_loop = op[38];\n        c.r_push_status = op[37]; c.r_pop_status = op[36];\n        c.r_push_pc = op[35]; c.r_pop_pc = op[34];\n", "")],
    # step 2: dual FADD/FSUB's second adder
    "k_fadd1": [("alu", "sharc_fadd u_fadd1 (.clk, .en(ce && x_go), .x(ax), .y(ay), .sub(1'b1)",
                 "sharc_fadd u_fadd1 (.clk, .en(1'b0), .x(32'h0), .y(32'h0), .sub(1'b1)")],
    # step 5: universal-register reads and writes kept for what the program reads or writes hot
    "k_ureg_hot": [("ops", "    4'h4: get_ureg = dag_rd(u[3], 2'd3, k);\n", ""),
                   ("ops", "    4'h6: case (u[3:0])\n          4'h4: get_ureg = Q.pcstk;", "    4'h6: " + "case (4'h0)\n          4'h4: get_ureg = Q.pcstk;"),
                   ("ops", "          4'ha: get_ureg = Q.mode2;\n", ""),
                   ("ops", "          4'hc: get_ureg = astat_read(c);\n          4'hd: get_ureg = Q.imask;\n          4'he: get_ureg = stky_now(c);\n", ""),
                   ("ops", "    4'hd: case (u[3:0])\n          4'hb: get_ureg = Q.px[31:0];", "    4'hd: case (4'h0)\n          4'hb: get_ureg = Q.px[31:0];")],
}
# step 3: the loop and status stacks at the depths the game reaches (LSTKP <= 2; one interrupt level)
VARIANTS["k_stacks"] = [("core", "    logic [5:0][31:0] lcstack, lastack;", "    logic [2:0][31:0] lcstack, lastack;"),
                        ("core", "    logic [4:0][31:0] ss_mode1, ss_astat;", "    logic [0:0][31:0] ss_mode1, ss_astat;")]
# step 4: the DMA parameter registers' cost (never written: an upper bound)
VARIANTS["k_dmaregs"] = [("ops", f"    8'h{r} = d;\n", "") for r in ['40: n.dma_int_index[0]', '41: n.dma_int_modifier[0]', '42: n.dma_int_count[0]', '43: n.dma_chain_ptr[0]', '44: n.dma_gen[0]', '45: n.dma_ext_index[0]', '46: n.dma_ext_modifier[0]', '47: n.dma_ext_count[0]', '48: n.dma_int_index[1]', '49: n.dma_int_modifier[1]', '4a: n.dma_int_count[1]', '4b: n.dma_chain_ptr[1]', '4c: n.dma_gen[1]', '4d: n.dma_ext_index[1]', '4e: n.dma_ext_modifier[1]', '4f: n.dma_ext_count[1]']]
# the five step-1 knockouts together
VARIANTS["k_step1"] = sum((VARIANTS[k] for k in ("k_favg", "k_mcops", "k_alufix", "k_shift", "k_mf", "k_type1", "k_pushpop")), [])


def run(name):
    d = HERE / f"x_{name}"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir()
    for f in SRC.glob("*"):
        shutil.copy(f, d / f.name)
    for which, old, new in VARIANTS[name]:
        p = d / FILES[which]
        t = p.read_text()
        assert old in t, (name, old[:60])
        p.write_text(t.replace(old, new, 1))
    shutil.copy(HERE / "synth_top.sv", d / "synth_top.sv")
    shutil.copy(HERE / "synth_sharc.sdc", d / "synth_sharc.sdc")
    shutil.copy(BOARD / "hornet_dpram.sv", d / "hornet_dpram.sv")
    qsf = (HERE / "synth_sharc.qsf").read_text().replace("../cpu/sharc2/", "").replace("../cpu/sharc2", ".") \
        .replace("../board/", "").replace("../cpu/sharc/", str(HERE.parent / "cpu/sharc").replace("\\", "/") + "/")
    (d / "exp.qsf").write_text(qsf)
    (d / "exp.qpf").write_text('PROJECT_REVISION = "exp"\n')
    subprocess.run([sys.executable, str(REPO / "scripts/hwlock.py"), "--require-no-jtag", f"area_exp {name}"], check=True)
    subprocess.run(["quartus_map", "exp"], cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rpt = (d / "output_files/exp.map.rpt").read_text(errors="replace") if (d / "output_files/exp.map.rpt").exists() else ""
    m = re.search(r"\|sharc2_core:dsp\|\s*;\s*([\d.]+) \(([\d.]+)\)", rpt)
    a = re.search(r"\|sharc2_alu:u_alu\|\s*;\s*([\d.]+) \(([\d.]+)\)", rpt)
    r = re.search(r"\|sharc2_core:dsp\|\s*;[^;]*;\s*([\d.]+) \(([\d.]+)\)", rpt)
    line = (f"{name:12s} core ALUTs {m.group(1) if m else '?'} (own {m.group(2) if m else '?'})  "
            f"alu {a.group(1) if a else '?'}  regs {r.group(1) if r else '?'}")
    print(line, flush=True)
    return line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    with ThreadPoolExecutor(a.j) as ex:
        list(ex.map(run, a.names or VARIANTS))


if __name__ == "__main__":
    main()
