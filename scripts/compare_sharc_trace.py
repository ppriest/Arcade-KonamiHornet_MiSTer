#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff sim/sharc_tb's trace against MAME's for a SHARC window.

    python scripts/compare_sharc_trace.py debug/gradius4-sharc3000 [--context 4] [--rtl rtl2.tr]

Both files: R0-15 I0-15 M0-15 ASTAT MODE1 IRPTL IMASK PCSTKP LSTKP CURLCNTR PCSTK, then
`PC: ...`, the state before each instruction. Reports the first PC or register divergence.
"""
import argparse
import sys
from pathlib import Path

NAMES = ([f"R{i}" for i in range(16)] + [f"I{i}" for i in range(16)] + [f"M{i}" for i in range(16)] +
         ["ASTAT", "MODE1", "IRPTL", "IMASK", "PCSTKP", "LSTKP", "CURLCNTR", "PCSTK"])
N = len(NAMES)


def load(path, limit):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) <= N or not p[N].endswith(":"):
                continue
            rows.append((int(p[N][:-1], 16), [int(x, 16) for x in p[:N]], " ".join(p[N + 1:])))
            if len(rows) >= limit:
                break
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--context", type=int, default=4)
    ap.add_argument("--rtl", default="rtl.tr", help="the bench's trace in the window (sharc2_tb: rtl2.tr)")
    a = ap.parse_args()
    d = Path(a.dir)
    rtl = load(d / a.rtl, 10**9)
    mame = load(d / "trace.tr", len(rtl))
    n = min(len(rtl), len(mame))
    for i in range(n):
        bad = [k for k in range(N) if rtl[i][1][k] != mame[i][1][k]]
        if rtl[i][0] == mame[i][0] and not bad:
            continue
        print(f"DIVERGENCE at instruction {i + 1} (state before it):")
        for j in range(max(0, i - a.context), min(n, i + 2)):
            flag = "  <--" if j == i else ""
            print(f"  #{j + 1:<8} MAME {mame[j][0]:06X} {mame[j][2]:<40} RTL {rtl[j][0]:06X}{flag}")
        if rtl[i][0] != mame[i][0]:
            print(f"  PC: MAME {mame[i][0]:06X}, RTL {rtl[i][0]:06X}")
        for k in bad:
            print(f"  {NAMES[k]:>8}: MAME {mame[i][1][k]:08X}, RTL {rtl[i][1][k]:08X}")
        return 1
    print(f"MATCH: {n} of {n} instructions agree in PC and all {N} registers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
