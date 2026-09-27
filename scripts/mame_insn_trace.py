#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The first N main-CPU instructions from reset, from MAME's debugger trace.

    python scripts/mame_insn_trace.py <set> 200000 [--regs all | --regs sp,ra]
    -> debug/<set>-insn/<set>.tr

One line per instruction: `PC: disassembly`, prefixed with the listed registers when
--regs is given. `all` is R0..R31, CR, LR, CTR, XER, MSR (the PPC state names); an unknown
name drops the prefix silently. The values are the state BEFORE the traced instruction
executes. The reference the RTL CPU's per-instruction export is compared against.

Why not the bus taps (mame_boot_trace.py): hornet maps PPC work RAM as DRC fastram
(hornet.cpp:1326), which bypasses Lua taps. The debugger trace sees every instruction.

MAME is run with -debug -debugger none; the trace is armed from an autoboot Lua script
(a -debugscript is not executed without a debugger UI). The trace runs far slower than
real time, so the run is stopped by line count, not emulated time.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REGS = [f"R{i}" for i in range(32)] + ["CR", "LR", "CTR", "XER", "MSR"]
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, mame_paths, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("n", type=int, help="instructions to keep")
    ap.add_argument("--regs", default="", help="'all', or register names, e.g. sp,ra")
    ap.add_argument("--width", type=int, default=8, help="hex digits per traced register")
    ap.add_argument("--cpu", default="maincpu")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds before giving up")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-insn"
    out.mkdir(parents=True, exist_ok=True)
    tr = out / f"{a.game}.tr"
    raw = out / f"{a.game}.raw.tr"
    for f in (tr, raw):
        f.unlink(missing_ok=True)

    action = ""
    if a.regs:
        regs = REGS if a.regs == "all" else [r.strip() for r in a.regs.split(",") if r.strip()]
        fmt = " ".join("%%0%dX" % a.width for _ in regs)
        action = ',{tracelog "' + fmt + ' ",' + ",".join(regs) + "}"
    lua = out / "arm.lua"
    lua.write_text(
        "local dbg = manager.machine.debugger\n"
        "if not dbg then print('INSN_NO_DEBUGGER') return end\n"
        # A tracelog action is a debugger command, so its register names resolve against
        # the VISIBLE cpu, not the traced one. Tracing anything but the main CPU needs
        # both set, or the names silently do not resolve and the prefix is dropped.
        f"dbg.visible_cpu = manager.machine.devices[':{a.cpu}']\n"
        f"dbg:command('trace {raw.as_posix()},{a.cpu},noloop{action}')\n"
        "dbg:command('go')\n"
        "print('INSN_ARMED')\n", encoding="utf-8")

    cmd = [str(exe), a.game, "-debug", "-debugger", "none", "-nowindow", "-video", "none",
           "-sound", "none", "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(lua), "-rompath", rompath(mame_dir)]
    p = subprocess.Popen(cmd, cwd=mame_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **NO_WINDOW)

    # Stop once the raw trace holds N lines. Bytes per line vary; poll a line count.
    t0, have = time.time(), 0
    while p.poll() is None and time.time() - t0 < a.timeout:
        time.sleep(2)
        if raw.exists():
            with open(raw, "rb") as f:
                have = sum(1 for _ in f)
            if have >= a.n:
                break
    if p.poll() is None:
        p.kill()
        p.wait()
    if not raw.exists():
        sys.exit("no trace written:\n" + p.stdout.read().decode(errors="replace")[-2000:])

    kept = 0
    with open(raw, encoding="utf-8", errors="replace") as src, open(tr, "w", encoding="utf-8") as dst:
        for line in src:
            if kept >= a.n:
                break
            dst.write(line)
            kept += 1
    raw.unlink()
    print(f"{kept} instructions -> {tr}")
    if kept < a.n:
        print(f"warning: MAME stopped or timed out after {kept} of {a.n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
