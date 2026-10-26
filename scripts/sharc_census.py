#!/usr/bin/env python3
"""Census of gradius4's SHARC program: which opcode classes, compute ops, conditions and universal
registers the program holds (static, over block0.bin as MAME packs it) and executes (dynamic, over
a window's MAME trace). Classes and op names from sharc_profile_report.py.

  python scripts/sharc_census.py debug/gradius4-sharc7500            # static, 0x20000-0x245FF
  python scripts/sharc_census.py debug/gradius4-sharc7500 --trace    # the window's trace.tr

The windows are scripts/mame_sharc_window.py's (block0.bin, trace.tr).
"""
import argparse
import collections
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sharc_profile_report import COMPUTE_CLASSES, compute_kind, op_class  # noqa: E402

UREG = {k: f"R{k}" for k in range(16)}
for g, nm, lo in ((0x10, "I", 0), (0x18, "M", 0), (0x20, "L", 0), (0x28, "B", 0),
                  (0x30, "I", 8), (0x38, "M", 8), (0x40, "L", 8), (0x48, "B", 8)):
    for k in range(8):
        UREG[g + k] = f"{nm}{k + lo}"
UREG.update({0x60: "FADDR", 0x61: "DADDR", 0x63: "PC", 0x64: "PCSTK", 0x65: "PCSTKP", 0x66: "LADDR",
             0x67: "CURLCNTR", 0x68: "LCNTR", 0x70: "USTAT1", 0x71: "USTAT2", 0x79: "IRPTL",
             0x7a: "MODE2", 0x7b: "MODE1", 0x7c: "ASTAT", 0x7d: "IMASK", 0x7e: "STKY", 0x7f: "IMASKP",
             0xdb: "PX", 0xdc: "PX1", 0xdd: "PX2"})

CONDITIONAL = {0x0100, 0x4000, 0x5000, 0x6000, 0x6080, 0x6100, 0x6180, 0x0200, 0x0400, 0x0600,
               0x0680, 0x0700, 0x0780, 0x0800, 0x0880, 0x0900, 0x0980, 0xc000, 0xe000, 0x0a00,
               0x0b00, 0x0e00}
JUMPS = {0x0600, 0x0680, 0x0700, 0x0780, 0x0800, 0x0880, 0x0900, 0x0980, 0x0a00, 0x0b00}
UREG_FIELD_39 = {0x1000, 0x1100, 0x1200, 0x1300, 0xa000, 0xa100, 0xb000, 0xb100, 0x0f00}
UREG_LOADS = {0x1000, 0x1200, 0xa000, 0xb000, 0x0f00}


def load_pm(d):
    """The 48-bit words of PM 0x20000-0x24FFF from block0.bin (sim/sharc2_tb/main.cpp's unpacking)."""
    b = (d / "block0.bin").read_bytes()
    block0 = struct.unpack(f"<{len(b) // 4}I", b)
    pm = {}
    for off in range(0x5000):
        slot = off >> 12
        base = (off & 0xfff) + (slot >> 1) * (3 << 12)
        if slot & 1:
            w = (block0[base + 0x2000] << 16) | (block0[base + 0x1000] & 0xffff)
        else:
            w = (block0[base] << 16) | (block0[base + 0x1000] >> 16)
        pm[0x20000 + off] = w
    return pm


def usrc_sel(op):
    """sharc2_ops.svh usrc_sel: the universal register an instruction reads as a source."""
    top = (op >> 39) & 0x1ff
    if (top >> 5) in (0b0100, 0b0101):
        return (op >> 23) & 0xff
    if (top >> 5) == 0b0111:
        return (op >> 36) & 0xff
    if (top >> 1) == 0b00010100:
        return 0x70 | ((op >> 32) & 0xf)
    if (top >> 1) in (0b00001100, 0b00001101, 0b00001110) or (top >> 3) == 0b000100 or (top >> 6) == 0b101:
        return (op >> 32) & 0xff
    return None


def census(pm, pcs, label):
    cls, comp, cond = collections.Counter(), collections.Counter(), collections.Counter()
    src, dst, sysbit = collections.Counter(), collections.Counter(), collections.Counter()
    jflags, dos, stacks, shimm = (collections.Counter() for _ in range(4))
    n = 0
    for pc, cnt in pcs.items():
        op = pm.get(pc)
        if op is None:
            continue
        bits, name = op_class(op)
        n += cnt
        cls[name] += cnt
        if bits in COMPUTE_CLASSES:
            ck = compute_kind(op & 0x7fffff)
            comp[ck[2] if ck else "(no compute field)"] += cnt
        if bits in CONDITIONAL:
            cond[(op >> 33) & 0x1f] += cnt
        u = usrc_sel(op)
        if bits == 0x7000:
            cond[(op >> 31) & 0x1f] += cnt
            dst[(op >> 23) & 0xff] += cnt
        if u is not None and bits not in UREG_FIELD_39 and bits not in (0x4000, 0x5000):
            src[u] += cnt
        if bits in (0x4000, 0x5000):
            (src if (op >> 31) & 1 else dst)[(op >> 23) & 0xff] += cnt
        if bits in UREG_FIELD_39:
            (dst if bits in UREG_LOADS else src)[(op >> 32) & 0xff] += cnt
        if bits == 0x1400:
            sysbit[(UREG[0x70 | ((op >> 32) & 0xf)], (op >> 37) & 7)] += cnt
        if bits in JUMPS:
            jflags[f"j{(op >> 26) & 1} la{(op >> 38) & 1} ci{(op >> 24) & 1} e{(op >> 25) & 1}"] += cnt
        if bits in (0x0c00, 0x0d00, 0x0e00):
            dos[(op >> 40) & 7] += cnt
        if bits == 0x1700:
            stacks[(op >> 34) & 0x3f] += cnt
        if bits in (0x8000, 0x0200):
            shimm[(op >> 16) & 0x3f] += cnt
    print(f"\n==== {label}: {n} instructions ({len(pcs)} distinct PCs)")

    def show(title, c, key=str, limit=64):
        print(title)
        for k, v in c.most_common(limit):
            print(f"  {key(k):40s} {v:9d} {100 * v / n:6.2f}%")

    show("opcode classes:", cls)
    show("compute ops:", comp)
    show("conditions:", cond, key=lambda k: f"cond {k:#04x}")
    show("ureg sources:", src, key=lambda k: UREG.get(k, hex(k)))
    show("ureg destinations:", dst, key=lambda k: UREG.get(k, hex(k)))
    show("sysreg bit ops (reg, op 0=set 1=clr 2=tgl 4=tst 5=xor):", sysbit)
    show("jump flags:", jflags)
    show("DO UNTIL kinds (op[42:40]):", dos)
    show("push/pop masks:", stacks)
    show("immediate shift ops:", shimm, key=lambda k: f"shift {k:#04x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--lo", type=lambda s: int(s, 0), default=0x20000)
    ap.add_argument("--hi", type=lambda s: int(s, 0), default=0x24600)
    a = ap.parse_args()
    d = Path(a.dir)
    pm = load_pm(d)
    if not a.trace:
        census(pm, {pc: 1 for pc in range(a.lo, a.hi) if pm[pc] != 0},
               f"static {d.name} {a.lo:#x}-{a.hi:#x} (non-zero words)")
        return
    pcs = collections.Counter()
    with open(d / "trace.tr", errors="replace") as f:
        for line in f:
            i = line.rfind(": ")
            if i < 0:
                continue
            j = line.rfind(" ", 0, i)
            try:
                pcs[int(line[j + 1:i], 16)] += 1
            except ValueError:
                pass
    census(pm, pcs, f"trace {d.name}")


if __name__ == "__main__":
    main()
