#!/usr/bin/env python3
"""Summarise a scripts/sharc_profile.py output directory.

  python scripts/sharc_profile_report.py DIR [--max-lines 2000000]

Per window: internal RAM footprint (merged runs per block), external accesses per frame,
external RAM footprint, sampled modes, interrupts, IOP/DMA writes; per trace: program range,
opcode class mix (sharcops_table.cpp), compute unit mix, float op keywords, PM-bus data
addresses, MODE1/MODE2/IMASK writes, loop/PC stack depth.
"""
import argparse
import collections
import csv
import re
import statistics
import struct
from pathlib import Path

# sharcops_table.cpp, in table order (first match wins), on the top 16 opcode bits
OPS = [
    (0xe000, 0x2000, "compute + dual DM/PM move"),
    (0xff00, 0x0100, "compute"),
    (0xf000, 0x4000, "compute + ureg DM/PM premod"),
    (0xf000, 0x5000, "compute + ureg DM/PM postmod"),
    (0xf180, 0x6000, "compute + DM->dreg immmod"),
    (0xf180, 0x6080, "compute + dreg->DM immmod"),
    (0xf180, 0x6100, "compute + PM->dreg immmod"),
    (0xf180, 0x6180, "compute + dreg->PM immmod"),
    (0xf000, 0x7000, "compute + ureg<->ureg"),
    (0xf000, 0x8000, "imm shift + DM/PM move"),
    (0xff00, 0x0200, "imm shift"),
    (0xff00, 0x0400, "compute + modify"),
    (0xff80, 0x0600, "jump direct"),
    (0xff80, 0x0680, "call direct"),
    (0xff80, 0x0700, "jump relative"),
    (0xff80, 0x0780, "call relative"),
    (0xff80, 0x0800, "jump indirect (+compute)"),
    (0xff80, 0x0880, "call indirect (+compute)"),
    (0xff80, 0x0900, "jump relative + compute"),
    (0xff80, 0x0980, "call relative + compute"),
    (0xe000, 0xc000, "jump indirect + compute + DM"),
    (0xe000, 0xe000, "jump relative + compute + DM"),
    (0xff00, 0x0a00, "RTS (+compute)"),
    (0xff00, 0x0b00, "RTI (+compute)"),
    (0xff00, 0x0c00, "DO UNTIL LCE (imm count)"),
    (0xff00, 0x0d00, "DO UNTIL LCE (ureg count)"),
    (0xff00, 0x0e00, "DO UNTIL condition"),
    (0xff00, 0x1000, "DM->ureg direct"),
    (0xff00, 0x1100, "ureg->DM direct"),
    (0xff00, 0x1200, "PM->ureg direct"),
    (0xff00, 0x1300, "ureg->PM direct"),
    (0xf100, 0xa000, "DM->ureg indirect"),
    (0xf100, 0xa100, "ureg->DM indirect"),
    (0xf100, 0xb000, "PM->ureg indirect"),
    (0xf100, 0xb100, "ureg->PM indirect"),
    (0xf000, 0x9000, "imm -> DM/PM"),
    (0xff00, 0x0f00, "imm -> ureg"),
    (0xff00, 0x1400, "sysreg bit op"),
    (0xff80, 0x1600, "modify I"),
    (0xff80, 0x1680, "bit reverse"),
    (0xff00, 0x1700, "push/pop stacks"),
    (0xff80, 0x0000, "NOP"),
    (0xff80, 0x0080, "IDLE"),
]
# classes whose low 23 bits are a compute field (sharcops.hxx calls COMPUTE on them)
COMPUTE_CLASSES = {0x2000, 0x0100, 0x4000, 0x5000, 0x6000, 0x6080, 0x6100, 0x6180, 0x7000, 0x0400,
                   0x0800, 0x0880, 0x0900, 0x0980, 0xc000, 0xe000, 0x0a00, 0x0b00}

ALU = {0x01: "ADD", 0x02: "SUB", 0x05: "ADD+CI", 0x06: "SUB+CI", 0x0a: "COMP", 0x21: "PASS",
       0x22: "NEG", 0x25: "+CI", 0x26: "+CI-1", 0x29: "INC", 0x2a: "DEC", 0x30: "ABS", 0x40: "AND",
       0x41: "OR", 0x42: "XOR", 0x43: "NOT", 0x61: "MIN", 0x62: "MAX", 0x63: "CLIP",
       0x81: "FADD", 0x82: "FSUB", 0x89: "FAVG", 0x8a: "FCOMP", 0x91: "FADDABS", 0x92: "FSUBABS",
       0xa1: "FPASS", 0xa2: "FNEG", 0xb0: "FABS", 0xbd: "SCALB", 0xc1: "LOGB", 0xc4: "RECIPS",
       0xc5: "RSQRTS", 0xc9: "FIX", 0xca: "FLOAT", 0xd9: "FIX BY", 0xda: "FLOAT BY",
       0xe0: "COPYSIGN", 0xe1: "FMIN", 0xe2: "FMAX", 0xe3: "FCLIP"}
MUL = {0x14: "MRF=0", 0x16: "MRB=0", 0x30: "FMUL", 0x40: "MUL UUI", 0x70: "MUL SSI",
       0xb0: "MRF+=SSI", 0xb2: "MRB+=SSI"}
SHF = {0x00: "LSHIFT", 0x02: "ROT", 0x08: "OR LSHIFT", 0x10: "FEXT", 0x12: "FEXT (SE)",
       0x19: "OR FDEP", 0x30: "BSET", 0x31: "BCLR", 0x33: "BTST"}
MULTI = {0x00: "MR->reg", 0x01: "reg->MR", 0x04: "MUL SSFR || ADD", 0x05: "MUL SSFR || SUB",
         0x18: "FMUL || FADD", 0x19: "FMUL || FSUB", 0x1a: "FMUL || FLOAT BY",
         0x1b: "FMUL || FIX BY", 0x1c: "FMUL || FAVG", 0x1d: "FMUL || FABS", 0x1e: "FMUL || FMAX",
         0x1f: "FMUL || FMIN"}


def op_class(op48):
    top = (op48 >> 32) & 0xffff
    for mask, bits, name in OPS:
        if top & mask == bits:
            return bits, name
    return None, "unknown"


def compute_kind(c):
    """(unit, fixed/float, op name) of a 23-bit compute field, or None when it is 0."""
    if c == 0:
        return None
    if c & 0x400000:
        mo = (c >> 16) & 0x3f
        if mo >= 0x30:
            return ("multifunction", "float", "FMUL || FADD/FSUB dual")
        name = MULTI.get(mo, f"multi {mo:02x}")
        return ("multifunction", "float" if mo >= 0x18 else "fixed", name)
    cu, op = (c >> 20) & 3, (c >> 12) & 0xff
    if cu == 0:
        if 0x70 <= op <= 0x7f:
            return ("ALU", "fixed", "dual ADD/SUB")
        if op >= 0xf0:
            return ("ALU", "float", "dual FADD/FSUB")
        return ("ALU", "float" if op & 0x80 else "fixed", ALU.get(op, f"alu {op:02x}"))
    if cu == 1:
        return ("multiplier", "float" if op == 0x30 else "fixed", MUL.get(op, f"mul {op:02x}"))
    if cu == 2:
        return ("shifter", "fixed", SHF.get(op >> 2, f"shift {op >> 2:02x}"))
    return ("?", "?", f"cu3 {op:02x}")


def runs(words, gap=0):
    out = []
    for w in sorted(words):
        if out and w <= out[-1][1] + 1 + gap:
            out[-1][1] = w
        else:
            out.append([w, w])
    return out


def fmt_runs(rs, width=4, limit=24):
    s = ", ".join(f"{a:0{width}x}-{b:0{width}x}" if a != b else f"{a:0{width}x}" for a, b in rs[:limit])
    return s + (f", ... ({len(rs)} runs)" if len(rs) > limit else "")


def pctl(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


# 48-bit PM address -> block-0/1 32-bit storage words touched, as MAME's pm_r/pm_w do it
def pm_storage(addr, wide):
    if not (0x20000 <= addr < 0x40000):
        return []
    blk = 0 if addr < 0x28000 else 1
    off = addr & 0x7fff
    if off >= 0x5000:
        return []                      # unmapped in MAME's pgm_2m
    slot, base = off >> 12, (off & 0xfff) + ((off >> 12) >> 1) * 0x3000
    hi = base + 0x2000 if slot & 1 else base
    return [(blk, hi), (blk, base + 0x1000)] if wide else [(blk, hi)]


PM_RE = re.compile(r"PM\(([^)]*)\)")


def pm_address(arg, I, M):
    parts = [p.strip() for p in arg.split(",")]
    def val(p):
        m = re.fullmatch(r"I(\d+)", p)
        if m:
            return I[int(m.group(1)) - 8], "I"
        m = re.fullmatch(r"M(\d+)", p)
        if m:
            return M[int(m.group(1)) - 8], "M"
        return int(p.replace("+", ""), 16) if not p.startswith("-") else -int(p[1:], 16), "N"
    vs = [val(p) for p in parts]
    if len(vs) == 1:
        return vs[0][0]
    (a, ka), (b, kb) = vs
    if ka == "I" and kb != "I":
        return a                        # post-modify: address is I before the update
    return a + b                        # pre-modify / direct+I


def analyse_trace(path, pm_bin, max_lines):
    pm = pm_bin.read_bytes()
    words = [struct.unpack_from("<IH", pm, i * 6) for i in range(len(pm) // 6)]
    code = {0x20000 + i: lo | (hi << 32) for i, (lo, hi) in enumerate(words)}
    cls = collections.Counter()
    comp = collections.Counter()
    compname = collections.Counter()
    kw = collections.Counter()
    pcs = set()
    n = 0
    flags = collections.Counter()
    pmacc = collections.Counter()
    pmaddr = {"r": set(), "w": set()}
    pmstore = set()
    sysw = collections.defaultdict(collections.Counter)
    maxl = maxp = 0
    vec = collections.Counter()
    prev_pc = None
    pending = None
    ids = []
    KW = ["RECIPS", "RSQRTS", "FIX", "FLOAT", "SCALB", "LOGB", "COPYSIGN", "COMP", "ABS", "MIN",
          "MAX", "CLIP", "PASS", "LSHIFT", "ASHIFT", "FEXT", "FDEP", "BSET", "BCLR", "BTST",
          "BTGL", "ROT", "EXP", "LEFTZ", "LEFTO", "FPACK", "FUNPACK", "MRF", "MRB", "SAT", "RND"]
    with open(path, errors="replace") as f:
        for line in f:
            if n >= max_lines:
                break
            parts = line.rstrip("\n").split(" ", 21)
            if len(parts) < 22:
                continue
            try:
                regs = [int(x, 16) for x in parts[:21]]
            except ValueError:
                continue
            rest = parts[21]
            pcs_s, _, dis = rest.partition(": ")
            pc = int(pcs_s, 16)
            n += 1
            I = regs[0:8]
            M = [r - (1 << 32) if r & 0x80000000 else r for r in regs[8:16]]
            mode1, mode2, imask, lstkp, pcstkp = regs[16:21]
            if pending:
                reg, txt = pending
                sysw[reg][f"{ {'MODE1': mode1, 'MODE2': mode2, 'IMASK': imask}[reg]:08x}"] += 1
                pending = None
            maxl, maxp = max(maxl, lstkp), max(maxp, pcstkp)
            if pc < 0x20080 and pc & 3 == 0 and prev_pc is not None and pc != prev_pc + 1:
                vec[pc] += 1
            prev_pc = pc
            pcs.add(pc)
            op = code.get(pc, 0)
            bits, name = op_class(op)
            cls[name] += 1
            if bits in COMPUTE_CLASSES:
                k = compute_kind(op & 0x7fffff)
                if k:
                    comp[(k[0], k[1])] += 1
                    compname[k[2]] += 1
            elif bits in (0x0200, 0x8000):
                comp[("shifter", "fixed (imm)")] += 1
            if "(DB)" in dis:
                flags["delayed branch (DB)"] += 1
            if dis.startswith("IF "):
                flags["conditional"] += 1
            if "(LA)" in dis:
                flags["loop abort (LA)"] += 1
            if "(CI)" in dis:
                flags["clear interrupt (CI)"] += 1
            for w in KW:
                if re.search(r"\b" + w + r"\b", dis):
                    kw[w] += 1
            for m in PM_RE.finditer(dis):
                wr = dis[m.end():].lstrip().startswith("=")
                try:
                    a = pm_address(m.group(1), I, M) & 0xffffff
                except ValueError:
                    continue
                wide = re.search(r"\bPX\b", dis) is not None
                pmacc[("w" if wr else "r") + (" 48" if wide else " 32")] += 1
                pmaddr["w" if wr else "r"].add(a)
                pmstore.update(pm_storage(a, wide))
            for reg in ("MODE1", "MODE2", "IMASK", "ASTAT", "STKY"):
                if re.search(r"(^|, )(" + reg + r" = |BIT (SET|CLEAR|TOGGLE|CLR|TGL) " + reg + r"\b)", dis) or \
                   re.search(r"POP STS|PUSH STS", dis) and reg == "MODE1":
                    sysw[reg + " instr"][re.sub(r"0x[0-9A-F]+", lambda x: x.group(0), dis)] += 1
                    if reg in ("MODE1", "MODE2", "IMASK"):
                        pending = (reg, dis)
            if re.search(r"(^|, )L\d+ = ", dis):
                flags["writes to L regs"] += 1
            if "IDLE" == dis.strip():
                ids.append(n)
    return dict(n=n, cls=cls, comp=comp, compname=compname, kw=kw, pcs=pcs, flags=flags,
                pmacc=pmacc, pmaddr=pmaddr, pmstore=pmstore, sysw=sysw, maxl=maxl, maxp=maxp,
                vec=vec, idles=len(ids), code=code)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--max-lines", type=int, default=2000000)
    a = ap.parse_args()
    d = Path(a.dir)

    wins = sorted(p.stem.split("_", 1)[1] for p in d.glob("frames_*.csv"))
    union = {0: set(), 1: set()}
    for w in wins:
        print(f"\n==================== window {w}")
        rows = list(csv.DictReader(open(d / f"frames_{w}.csv")))
        print(f"frames {rows[0]['frame']}-{rows[-1]['frame']} ({len(rows)})")
        print(f"{'counter':16s} {'min':>8s} {'median':>9s} {'p95':>8s} {'max':>8s}")
        for k in rows[0]:
            if k == "frame":
                continue
            v = [int(r[k]) for r in rows]
            if max(v) == 0:
                continue
            print(f"{k:16s} {min(v):8d} {statistics.median(v):9.0f} {pctl(v, 95):8d} {max(v):8d}")
        # internal footprint
        R = {0: set(), 1: set()}
        W = {0: set(), 1: set()}
        for line in open(d / f"int_{w}.txt"):
            b, word, r, wr = line.split()
            b, word = int(b), int(word, 16)
            if int(r):
                R[b].add(word)
            if int(wr):
                W[b].add(word)
        for b in (0, 1):
            u = R[b] | W[b]
            union[b] |= u
            print(f"block{b}: {len(u)} words touched (read {len(R[b])}, written {len(W[b])}, "
                  f"read-only {len(R[b] - W[b])}, write-only {len(W[b] - R[b])})")
            print(f"  runs (gap<=16): {fmt_runs(runs(u, 16), limit=40)}")
            print(f"  exact runs: {len(runs(u))}")
        ext = collections.defaultdict(set)
        for line in open(d / f"ext_{w}.txt"):
            addr, r, wr = line.split()
            addr = int(addr, 16)
            reg = "ram500" if addr < 0x1000000 else "ram1400"
            if int(r):
                ext[reg + " r"].add(addr)
            if int(wr):
                ext[reg + " w"].add(addr)
        for reg in ("ram500", "ram1400"):
            u = ext[reg + " r"] | ext[reg + " w"]
            if u:
                print(f"{reg}: {len(u)} words (read {len(ext[reg + ' r'])}, written {len(ext[reg + ' w'])}); "
                      f"runs(gap<=64): {fmt_runs(runs(u, 64), 7, 12)}")
        # sampled state
        H = collections.defaultdict(collections.Counter)
        for line in open(d / f"samp_{w}.txt"):
            k, v, c = line.split()
            H[k][v] += int(c)
        tot = sum(H["MODE1"].values())
        print(f"samples {tot}")
        for k in ("MODE1", "MODE2", "IMASK", "LSTKP", "PCSTKP"):
            print(f"  {k}: " + ", ".join(f"{v}:{c}" for v, c in H[k].most_common(8)))
        ls = [k for k in H if re.fullmatch(r"L\d+", k)]
        print("  nonzero L regs sampled: " + (", ".join(f"{k}={dict(H[k])}" for k in sorted(ls)) or "none"))
        pcs = {int(v, 16): c for v, c in H["PC"].items()}
        if pcs:
            print(f"  fraction of samples at the IDLE loop (PC 2003b): {pcs.get(0x2003b, 0) / tot:.3f}")
            print(f"  sampled PC min {min(pcs):x} max {max(pcs):x} distinct {len(pcs)}; "
                  f"top: " + ", ".join(f"{p:x}:{c}" for p, c in sorted(pcs.items(), key=lambda x: -x[1])[:5]))
        # interrupts
        irq = [l.split() for l in open(d / "irq.txt") if l.split()[1:2] == [w]]
        hdr = open(d / "irq.txt").readline().split()[1:]
        cols = list(zip(*[[int(x) for x in r[2:]] for r in irq if "?" not in r]))
        print("interrupt entries per frame (min/median/max): " + ", ".join(
            f"{h} {min(c)}/{statistics.median(c):.0f}/{max(c)}" for h, c in zip(hdr, cols) if max(c)))

    for b in (0, 1):
        print(f"all windows, block{b}: {len(union[b])} words; runs(gap<=16): {fmt_runs(runs(union[b], 16), limit=40)}")

    # IOP / DMA
    print("\n==================== IOP writes")
    iop = collections.defaultdict(collections.Counter)
    tcb = collections.defaultdict(list)
    per_frame = collections.defaultdict(collections.Counter)
    for line in open(d / "iop.txt"):
        p = line.split()
        f = int(p[0])
        if p[1] == "T":
            tcb[int(p[2])].append((f, [int(x, 16) for x in p[3:]]))
            continue
        reg, val = int(p[1], 16), int(p[2], 16)
        iop[reg][val] += 1
        if reg in (0x1c, 0x1d) and val & 1:
            per_frame[f][reg] += 1
    for reg in sorted(iop):
        top = iop[reg].most_common(4)
        print(f"  {reg:02x}: {sum(iop[reg].values())} writes; " + ", ".join(f"{v:08x}x{c}" for v, c in top))
    for reg, ch in ((0x1c, 6), (0x1d, 7)):
        for w in wins:
            rows = list(csv.DictReader(open(d / f"frames_{w}.csv")))
            fs = [int(r["frame"]) for r in rows]
            v = [per_frame[f][reg] for f in fs]
            print(f"  DMA{ch} starts/frame in {w}: min {min(v)} median {statistics.median(v):.0f} max {max(v)}")
    for ch, lst in tcb.items():
        ii = [t[1][0] for t in lst]
        c = [t[1][2] for t in lst]
        ei = [t[1][4] for t in lst]
        print(f"  DMA{ch} chained TCBs: {len(lst)}; II {min(ii):x}-{max(ii):x}, C {min(c)}-{max(c)}, "
              f"EI {min(ei):x}-{max(ei):x}, EM {collections.Counter(t[1][5] for t in lst).most_common(3)}, "
              f"CP {collections.Counter(t[1][3] for t in lst).most_common(3)}")

    # traces
    for tr in sorted(d.glob("trace_*.tr")):
        name = tr.stem.split("_", 1)[1]
        pm_bin = d / f"pm_{name}.bin"
        same = pm_bin.read_bytes() == (d / f"pm_{name}_end.bin").read_bytes()
        t = analyse_trace(tr, pm_bin, a.max_lines)
        print(f"\n==================== trace {name}: {t['n']} instructions; PM unchanged over trace: {same}")
        pcs = t["pcs"]
        print(f"PC min {min(pcs):x} max {max(pcs):x}, distinct {len(pcs)}; IDLE executed {t['idles']}")
        code_words = set()
        for p in pcs:
            code_words.update(pm_storage(p, True))
        print(f"code storage (block0 words, MAME packing) of executed PCs: {len(code_words)}; "
              f"runs(gap<=16): {fmt_runs(runs({w for b, w in code_words if b == 0}, 16), limit=12)}")
        tot = t["n"]
        print("opcode class mix:")
        for k, v in t["cls"].most_common():
            print(f"  {k:32s} {v:9d} {100 * v / tot:6.2f}%")
        print("compute by unit:")
        for k, v in t["comp"].most_common():
            print(f"  {k[0]:14s} {k[1]:12s} {v:9d} {100 * v / tot:6.2f}%")
        print("compute ops: " + ", ".join(f"{k} {v}" for k, v in t["compname"].most_common(40)))
        print("disassembly keywords: " + ", ".join(f"{k} {v}" for k, v in t["kw"].most_common()))
        print("flags: " + ", ".join(f"{k} {v}" for k, v in t["flags"].most_common()))
        print(f"PM-bus data accesses: {dict(t['pmacc'])}")
        for rw in ("r", "w"):
            if t["pmaddr"][rw]:
                print(f"  PM {rw} addresses: {fmt_runs(runs(t['pmaddr'][rw], 16), 6, 12)}")
        if t["pmstore"]:
            print(f"  PM data storage words (MAME packing): " + "; ".join(
                f"block{b}: {fmt_runs(runs({w for bb, w in t['pmstore'] if bb == b}, 16), limit=10)}" for b in (0, 1)))
        print(f"max LSTKP {t['maxl']}, max PCSTKP {t['maxp']}")
        print("vector entries (non-sequential arrival at 0x20000+4n): " +
              ", ".join(f"{p:x}:{c}" for p, c in sorted(t["vec"].items())))
        for k, c in t["sysw"].items():
            print(f"  {k}: " + "; ".join(f"{v} x{n}" for v, n in c.most_common(10)))


if __name__ == "__main__":
    main()
