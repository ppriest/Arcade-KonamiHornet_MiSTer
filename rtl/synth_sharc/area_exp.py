#!/usr/bin/env python3
"""Where sharc2_core's logic goes: synthesise (quartus_map only) copies of the core with one
part removed each, and print the core's own combinational ALUTs. Run in rtl/synth_sharc.

    python area_exp.py [name ...]
"""
import re, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "cpu/sharc2"
EXP = HERE / "exp"

# name -> list of (old, new) replacements in sharc2_core.sv / sharc2_ops.svh
VARIANTS = {
    "base": [],
    "no_swap": [("core", "        if (swap_req != 0 && !x_valid && w_lwe == 0 && !w_on && ww_we == 0) begin", "        if (1'b0) begin")],
    "no_dmae": [("core", "assign e_start = !e_busy && run && !booting &&", "assign e_start = 1'b0 && !e_busy && run && !booting &&")],
    "no_step": [("core", "            case (k0)\n            4'(OP_CLEARINT)", "            case (4'd14)\n            4'(OP_CLEARINT)")],
    "no_loopend": [("core", "                if (le) op_loopend(c);\n", "")],
    "no_fsirq": [("core", "                if (irq_take(pend)) op_irq(c, pend);\n", "")],
    "no_fuse": [("core", "                if (fz && ok)\n", "                if (1'b0)\n")],
    "no_handler": [("core", "        execute_op(c, x_op, (xph == XS_EXEC) ? rq_n.pre_cond : x_rq.pre_cond);\n", "")],
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
}


def run(name):
    EXP.mkdir(exist_ok=True)
    for f in SRC.glob("*"):
        shutil.copy(f, EXP / f.name)
    files = {"core": EXP / "sharc2_core.sv", "ops": EXP / "sharc2_ops.svh"}
    for which, old, new in VARIANTS[name]:
        t = files[which].read_text()
        assert old in t, (name, old[:50])
        files[which].write_text(t.replace(old, new, 1))
    qsf = (HERE / "synth_sharc.qsf").read_text().replace("../cpu/sharc2/", "exp/").replace("../cpu/sharc2", "exp")
    (HERE / "exp.qsf").write_text(qsf)
    (HERE / "exp.qpf").write_text('PROJECT_REVISION = "exp"\n')
    subprocess.run(["quartus_map", "exp"], cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rpt = (HERE / "output_files/exp.map.rpt").read_text(errors="replace")
    m = re.search(r"\|sharc2_core:dsp\|\s*;\s*([\d.]+) \(([\d.]+)\)", rpt)
    a = re.search(r"\|sharc2_alu:u_alu\|\s*;\s*([\d.]+) \(([\d.]+)\)", rpt)
    print(f"{name:12s} core ALUTs {m.group(1) if m else '?'} (own {m.group(2) if m else '?'})  alu {a.group(1) if a else '?'}", flush=True)


for n in (sys.argv[1:] or VARIANTS):
    run(n)
