#!/usr/bin/env python3
"""Sample the stp revision's probes H and V while the game runs, to find what limits the frame
rate: per sample, buffer swaps against displayed frames between two H reads about 3 s apart, and
the last whole frame's Voodoo busy and texture-fill clocks, SHARC idle clocks and port A busy
clocks (clk_sys clocks; a frame is 1,095,680).

    python scripts/perf_sample.py [--n 40] [--out debug/perf_sample.csv]

Each read takes the JTAG lock through read_issp.py.
"""
import argparse
import csv
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIELDS_H = ("swaps", "frame", "dsp_idle_clk", "a_busy_clk", "b_busy_clk", "v_wait_clk")
FIELDS_V = ("busy_clk", "tri_clk", "tex_hold_clk", "tex_fills", "triangles", "fifo_full_clk")


def read(inst):
    p = subprocess.run([sys.executable, str(REPO / "scripts" / "read_issp.py"), inst],
                       capture_output=True, text=True)
    out = {}
    for line in p.stdout.splitlines():
        m = re.search(r"\|  (\w+)\s+(\S+)$", line)
        if m:
            v = m.group(2)
            out[m.group(1)] = int(v, 16) if v.startswith("0x") else (int(v) if v.isdigit() else v)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--out", default=str(REPO / "debug" / "perf_sample.csv"))
    a = ap.parse_args()
    cols = ["t", "frames", "swaps"] + [f"h_{k}" for k in FIELDS_H[2:]] + [f"v_{k}" for k in FIELDS_V]
    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for _ in range(a.n):
            # two H reads back to back (about 3 s, under the 8-bit counters' 256 frames), then V
            h0 = read("H")
            h = read("H")
            v = read("V")
            if not all(k in d for d in (h0, h) for k in ("frame", "swaps")):
                continue
            df = (h["frame"] - h0["frame"]) % 256
            ds = (h["swaps"] - h0["swaps"]) % 256
            row = [round(time.time(), 1), df, ds] + [h.get(k) for k in FIELDS_H[2:]] + [v.get(k) for k in FIELDS_V]
            w.writerow(row)
            f.flush()
            print(" ".join(f"{c}={x}" for c, x in zip(cols, row)))
    print("->", a.out)


if __name__ == "__main__":
    main()
