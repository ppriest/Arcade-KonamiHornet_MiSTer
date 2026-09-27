#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Group sim/voodoo_tb's pixel differences by the render state of the triangle that drew them.

    python scripts/voodoo_diff_by_state.py debug/gradius4-voodoo7500 [--min 8]

Replays writes.txt's register stream; at each triangleCMD / ftriangleCMD the triangle's pixels
(top-left fill of vertices A, B, C, from the 12.4 or float vertex registers) are marked as last
drawn by it. Depth-test losers are not modelled: a pixel goes to the last triangle covering it.
Each pixel of the drawn buffer where rtl_fbram.bin and end/fbram.bin differ by --min or more in
any channel is then counted under that triangle's (fbzColorPath, fbzMode, alphaMode, textureMode,
tLOD). Pixels no triangle covers are counted under "fast fill".
"""
import argparse
import struct
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

W, H, ROW = 512, 384, 512
REG = dict(vertexAx=0x02, vertexAy=0x03, vertexBx=0x04, vertexBy=0x05, vertexCx=0x06, vertexCy=0x07,
           triangleCMD=0x20, fvertexAx=0x22, fvertexAy=0x23, fvertexBx=0x24, fvertexBy=0x25,
           fvertexCx=0x26, fvertexCy=0x27, ftriangleCMD=0x40, fbzColorPath=0x41, fogMode=0x42,
           alphaMode=0x43, fbzMode=0x44, textureMode=0xC0, tLOD=0xC1)


def s12_4(v):
    v &= 0xFFFF
    return (v - 0x10000 if v & 0x8000 else v) / 16.0


def f32(v):
    return struct.unpack("<f", struct.pack("<I", v))[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--min", type=int, default=8)
    a = ap.parse_args()
    d = Path(a.dir)

    regs = defaultdict(int)
    tmu = defaultdict(int)
    owner = np.full((H, W), -1, dtype=np.int32)
    states = []
    ys, xs = np.mgrid[0:H, 0:W]
    px, py = xs + 0.5, ys + 0.5
    for line in open(d / "writes.txt"):
        if line[0] != "W":
            continue
        _, off, data = line.split()
        off, data = int(off, 16), int(data, 16)
        chip, r = (off >> 8) & 0xF, off & 0xFF
        if chip in (0, 2) and r >= 0xC0:
            tmu[r] = data
        if chip in (0, 1):
            regs[r] = data
        if chip in (0, 1) and r in (REG["triangleCMD"], REG["ftriangleCMD"]):
            if r == REG["triangleCMD"]:
                v = [(s12_4(regs[REG[k + "x"]]), s12_4(regs[REG[k + "y"]])) for k in ("vertexA", "vertexB", "vertexC")]
            else:
                v = [(f32(regs[REG["f" + k + "x"]]), f32(regs[REG["f" + k + "y"]])) for k in ("vertexA", "vertexB", "vertexC")]
            (ax, ay), (bx, by), (cx, cy) = v
            area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            if area == 0:
                continue
            sgn = 1 if area > 0 else -1

            def edge(x0, y0, x1, y1):
                return sgn * ((x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)) >= 0
            m = edge(ax, ay, bx, by) & edge(bx, by, cx, cy) & edge(cx, cy, ax, ay)
            owner[m] = len(states)
            states.append((regs[REG["fbzColorPath"]], regs[REG["fbzMode"]], regs[REG["alphaMode"]],
                           tmu[REG["textureMode"]], tmu[REG["tLOD"]]))

    e = np.frombuffer(open(d / "end/fbram.bin", "rb").read()[:ROW * H * 2], dtype="<u2").reshape(H, ROW)[:, :W]
    r = np.frombuffer(open(d / "rtl_fbram.bin", "rb").read()[:ROW * H * 2], dtype="<u2").reshape(H, ROW)[:, :W]
    e, r = e.astype(np.int32), r.astype(np.int32)
    dr = np.abs((e >> 11) - (r >> 11))
    dg = np.abs(((e >> 5) & 63) - ((r >> 5) & 63))
    db = np.abs((e & 31) - (r & 31))
    big = np.maximum(np.maximum(dr, dg), db) >= a.min
    print(f"{len(states)} triangles; {int(big.sum())} pixels differ by {a.min} or more")
    per = Counter()
    tot = Counter()
    for t in range(-1, len(states)):
        m = owner == t
        key = "fast fill" if t < 0 else "cp=%08X fz=%08X am=%08X tm=%08X lod=%08X" % states[t]
        per[key] += int((big & m).sum())
        tot[key] += int(m.sum())
    for k, n in per.most_common(15):
        print(f"{n:7d} of {tot[k]:7d}  {k}")


if __name__ == "__main__":
    main()
