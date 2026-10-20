#!/usr/bin/env python3
"""Clocks per instruction of an in-order, one-issue SHARC pipeline on a MAME window's trace.

    python scripts/sharc_pipe_model.py debug/gradius4-sharc7500 [--n 2000000]

Reads the PC stream from <win>/rtl.tr (or trace.tr) with its opcodes, and
models, per data register R0-R15 and ASTAT, when its value is ready: an instruction issues when every
register it reads is ready. Latencies are per result class; branch refill costs per kind.
IDLE is left out. Alternate register sets, DMA and external-bus waits are not modelled.
"""
import argparse
import struct
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("win")
ap.add_argument("--n", type=int, default=2_000_000)
args = ap.parse_args()
win = Path(args.win)

OPS = {}


def opcode(pc):
    return OPS[pc]


def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


def compute_rw(c):
    """(reads, writes with their class) of a compute field; class 'fp' or 'fx'."""
    if c == 0:
        return set(), {}
    if bits(c, 22, 22):
        mop = bits(c, 21, 16)
        fm, fa = bits(c, 15, 12), bits(c, 11, 8)
        xm, ym, xa, ya = bits(c, 7, 6), 4 + bits(c, 5, 4), 8 + bits(c, 3, 2), 12 + bits(c, 1, 0)
        if mop in (0, 1):
            rn = bits(c, 11, 8)
            return ({rn} if mop == 1 else set()), ({rn: "fx"} if mop == 0 else {})
        if mop in (4, 5):
            return {xm, ym, xa, ya}, {fm: "fx", fa: "fx"}
        w = {fm: "fp", fa: "fp"}
        if mop in (0x1c, 0x1d, 0x1e, 0x1f) or bits(c, 21, 20) == 3:   # dual add/sub: Rs too
            w[bits(c, 19, 16)] = "fp"
        return {xm, ym, xa, ya}, w
    cu, op = bits(c, 21, 20), bits(c, 19, 12)
    rn, rx, ry = bits(c, 11, 8), bits(c, 7, 4), bits(c, 3, 0)
    if cu == 0:
        cls = "fp" if op & 0x80 else "fx"
    elif cu == 1:
        cls = "fp" if op == 0x30 else "fx"
    else:
        cls = "fx"
    reads = {rx, ry}
    if cu == 2:
        reads.add(rn)                        # the OR forms read Rn
    return reads, {rn: cls}


def decode(op):
    """(reads, writes {reg: class}, kind) for one opcode."""
    top = bits(op, 47, 39)
    comp = bits(op, 22, 0)
    reads, writes = set(), {}
    kind = "seq"
    has_comp = False
    if bits(top, 8, 6) == 0b001:
        has_comp = True
        pmd, dmd = bits(op, 26, 23), bits(op, 36, 33)
        (reads.add(pmd) if bits(op, 37, 37) else writes.__setitem__(pmd, "ld"))
        (reads.add(dmd) if bits(op, 44, 44) else writes.__setitem__(dmd, "ld"))
    elif top in (0b000000010, 0b000000011):
        has_comp = True
    elif bits(top, 8, 5) in (0b0100, 0b0101):
        has_comp = True
        u, d = bits(op, 30, 23), bits(op, 31, 31)
        if u < 0x10:
            (reads.add(u) if d else writes.__setitem__(u, "ld"))
    elif bits(top, 8, 5) == 0b0110:
        has_comp = True
        dr, d = bits(op, 26, 23), bits(op, 39, 39)
        (reads.add(dr) if d else writes.__setitem__(dr, "ld"))
    elif bits(top, 8, 5) == 0b0111:
        has_comp = True
        src, dst = bits(op, 43, 36), bits(op, 30, 23)
        if src < 0x10:
            reads.add(src)
        if dst < 0x10:
            writes[dst] = "fx"
    elif bits(top, 8, 5) == 0b1000 or top in (0b000000100, 0b000000101):
        reads |= {bits(op, 7, 4), bits(op, 3, 0)}
        writes[bits(op, 7, 4)] = "fx"
        if bits(top, 8, 5) == 0b1000:
            dr, d = bits(op, 26, 23), bits(op, 31, 31)
            (reads.add(dr) if d else writes.__setitem__(dr, "ld"))
    elif top in (0b000001000, 0b000001001):
        has_comp = True
    elif top in (0b000001100, 0b000001101, 0b000001110, 0b000001111):
        kind = "jump"
    elif top in (0b000010000, 0b000010001, 0b000010010, 0b000010011):
        kind = "jump"
        has_comp = True
    elif bits(top, 8, 7) == 0b11:
        kind = "jump"
        has_comp = True
        dr = bits(op, 26, 23)
        (reads.add(dr) if bits(op, 44, 44) else writes.__setitem__(dr, "ld"))
    elif bits(top, 8, 1) in (0b00001010, 0b00001011):
        kind = "jump"
        has_comp = True
    elif bits(top, 8, 3) == 0b000100:
        u = bits(op, 39, 32)
        if u < 0x10:
            (reads.add(u) if bits(op, 40, 40) else writes.__setitem__(u, "ld"))
    elif bits(top, 8, 6) == 0b101:
        u = bits(op, 39, 32)
        if u < 0x10:
            (reads.add(u) if bits(op, 40, 40) else writes.__setitem__(u, "ld"))
    elif top == 0b000000001:
        kind = "idle"
    if has_comp:
        r, w = compute_rw(comp)
        reads |= r
        for k, v in w.items():
            writes.setdefault(k, v)
        if w:
            writes[16] = max(w.values(), key=lambda c: c == "fp")   # flags of the compute
    if bits(top, 8, 5) == 0b0111:
        cond = bits(op, 35, 31)
    elif bits(top, 8, 6) in (0b001, 0b101) or bits(top, 8, 5) in (0b1001,) or top == 0b000000001             or bits(top, 8, 3) == 0b000100 or bits(top, 8, 1) in (0b00001111, 0b00001100, 0b00001101, 0b00010100, 0b00010111)             or top == 0b000101100:
        cond = 31                                  # no condition field
    else:
        cond = bits(op, 37, 33)
    if cond != 31:
        reads.add(16)
    return reads, writes, kind


def pcs():
    f = win / "rtl.tr"
    if not f.exists():
        f = win / "trace.tr"
    with open(f) as fh:
        for k, line in enumerate(fh):
            if k >= args.n:
                break
            p = line.rfind(": ")
            pc = int(line[p - 6:p], 16)
            OPS.setdefault(pc, int(line[p + 2:p + 14], 16))
            yield pc


dec = {}
stream = []
for pc in pcs():
    if pc not in dec:
        dec[pc] = decode(opcode(pc))
    stream.append(pc)

configs = [
    # name, latencies (fx, fp, ld), taken-jump refill, delayed-jump refill
    ("ideal 1/1/1 b0", 1, 1, 1, 0, 0),
    ("1/2/2 b2", 1, 2, 2, 2, 0),
    ("1/3/2 b2", 1, 3, 2, 2, 0),
    ("2/3/2 b2", 2, 3, 2, 2, 0),
    ("1/3/3 b3", 1, 3, 3, 3, 1),
    ("2/4/3 b3", 2, 4, 3, 3, 1),
]
n_exec = sum(1 for pc in stream if dec[pc][2] != "idle")
print(f"{len(stream)} trace lines, {n_exec} non-IDLE instructions, {len(dec)} distinct PCs")
for name, lfx, lfp, lld, bj, bd in configs:
    lat = {"fx": lfx, "fp": lfp, "ld": lld}
    ready = [0] * 17
    t = 0
    count = 0
    stall_data = stall_br = 0
    prev = None
    for k, pc in enumerate(stream):
        reads, writes, kind = dec[pc]
        if kind == "idle":
            prev = None
            continue
        issue = t + 1
        if prev is not None and pc != prev + 1:
            # a discontinuity: a jump here or two back (delayed), else a loop end or interrupt
            pk = dec[prev][2]
            p2 = stream[k - 3] if k >= 3 else None
            if pk == "jump" and not bits(opcode(prev), 26, 26):
                issue += bj; stall_br += bj
            elif p2 is not None and dec[p2][2] == "jump":
                issue += bd; stall_br += bd
        need = max([ready[r] for r in reads], default=0)
        if need > issue:
            stall_data += need - issue
            issue = need
        for r, c in writes.items():
            ready[r] = issue + lat[c]
        t = issue
        prev = pc
        count += 1
    print(f"  {name:16s} CPI {t / count:5.3f}  data stalls {stall_data / count:5.3f}  "
          f"branch {stall_br / count:5.3f}")
