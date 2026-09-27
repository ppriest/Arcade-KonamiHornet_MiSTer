#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff the RTL CPU's instruction trace against MAME's.

    python scripts/compare_insn_trace.py gradius4 [--context 4] [--skip-regs TBLO]

Inputs, one line per instruction, R0..R31 CR LR CTR XER MSR then `PC: ...`:
  debug/<set>-insn/<set>.tr   MAME (scripts/mame_insn_trace.py --regs all), state BEFORE the
                              instruction executes
  debug/<set>-insn/rtl.tr     sim/ppc_tb, state as the core's dbg_exec export reports it

Reports the first PC or register divergence.

MAME's recompiler skips a CR or XER flag update that a later instruction overwrites before any
reads it (the front end's register liveness), so MAME's traced CR/XER are not always the
architectural values. A CR/XER-only mismatch is therefore reported only if it has not
re-converged within --flag-window instructions; GPRs, MSR, LR, CTR and PC must match on
every line.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NAMES = [f"R{i}" for i in range(32)] + ["CR", "LR", "CTR", "XER", "MSR"]
NREG = len(NAMES)


def load(path, limit):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) <= NREG or not p[NREG].endswith(":"):
                continue
            rows.append((int(p[NREG][:-1], 16), [int(x, 16) for x in p[:NREG]], " ".join(p[NREG + 1:])))
            if len(rows) >= limit:
                break
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--context", type=int, default=4)
    ap.add_argument("--limit", type=int, default=10**9)
    ap.add_argument("--flag-window", type=int, default=64)
    ap.add_argument("--dir", default=None, help="a window from mame_ppc_window.py (trace.tr, rtl.tr)")
    a = ap.parse_args()
    if a.dir:
        d = Path(a.dir)
        ref = d / "trace.tr"
    else:
        d = REPO / "debug" / f"{a.set}-insn"
        ref = d / f"{a.set}.tr"
    rtl = load(d / "rtl.tr", a.limit)
    mame = load(ref, len(rtl) + 1)
    n = min(len(rtl), len(mame))
    FLAGS = {NAMES.index("CR"), NAMES.index("XER")}
    pending = None          # first instruction of an open CR/XER-only mismatch
    tolerated = 0
    for i in range(n):
        pc_ok = rtl[i][0] == mame[i][0]
        bad = [k for k in range(NREG) if rtl[i][1][k] != mame[i][1][k]]
        hard = [k for k in bad if k not in FLAGS]
        if pc_ok and not bad:
            if pending is not None:
                tolerated += 1
            pending = None
            continue
        if pc_ok and not hard:
            if pending is None:
                pending = i
            if i - pending < a.flag_window:
                continue
            i = pending
            bad = [k for k in range(NREG) if rtl[i][1][k] != mame[i][1][k]]
        print(f"DIVERGENCE at instruction {i + 1} (state before it):")
        for j in range(max(0, i - a.context), min(n, i + 2)):
            flag = "  <--" if j == i else ""
            print(f"  #{j + 1:<8} MAME {mame[j][0]:08X} {mame[j][2]:<32} RTL {rtl[j][0]:08X}{flag}")
        if rtl[i][0] != mame[i][0]:
            print(f"  PC: MAME {mame[i][0]:08X}, RTL {rtl[i][0]:08X}")
        for k in bad:
            print(f"  {NAMES[k]:>3}: MAME {mame[i][1][k]:08X}, RTL {rtl[i][1][k]:08X}")
        if pending is not None and pending != i:
            print(f"  (a CR/XER-only mismatch was open from instruction {pending + 1})")
        return 1
    print(f"MATCH: {n} of {n} instructions agree in PC and all {NREG} registers "
          f"({tolerated} transient CR/XER differences from MAME's dead-flag elimination)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
