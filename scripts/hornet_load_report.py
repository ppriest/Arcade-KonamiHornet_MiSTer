#!/usr/bin/env python3
"""Summarise a hornet_load.py run: per-phase min/median/p95/max of the
per-frame counters, SHARC wait-loop breakdown, and the Voodoo modes used.

  python scripts/hornet_load_report.py <run dir> [--sr 20000]
"""
import argparse
import csv
import re
import statistics
from collections import Counter, defaultdict
from pathlib import Path

# SHARC wait loops in gradius4 (ver JAC) internal program memory, from a
# debugger dump of 0x20000-0x24fff; the code is identical in attract and play.
SH_IDLE = {0x2003B, 0x2003C}                       # IDLE ; JUMP self
SH_VWAIT = set(range(0x200F1, 0x2010A)) | set(range(0x20886, 0x2088C))  # Voodoo status polls
SH_DMAWAIT_STARTS = [
    0x200DB, 0x20118, 0x20125, 0x20154, 0x20788, 0x20792, 0x2079C, 0x207A6, 0x207AF, 0x207B9,
    0x207C0, 0x207D2, 0x207DC, 0x207E6, 0x207F0, 0x20971, 0x20982, 0x20992, 0x2099C, 0x209A2,
    0x209C2, 0x209EC, 0x20A13, 0x20A33, 0x20A5A, 0x20A7C, 0x20AE0, 0x20B04, 0x21D10, 0x21D12,
    0x21D37, 0x21D47, 0x21D9D, 0x21DC6, 0x21DD3, 0x21E22, 0x21E43, 0x21E52, 0x21EAF, 0x21EC6,
    0x21ED8, 0x21F27, 0x21F3F, 0x21F4E, 0x21F99, 0x21FAE, 0x21FB9, 0x22013, 0x22098, 0x22114,
    0x22197, 0x22205, 0x2226A, 0x24A1F]                # BIT TEST IRPTL 0x20000 (DMA ch7 done)
SH_DMAWAIT = {a for s in SH_DMAWAIT_STARTS for a in (s, s + 1)}
SH_FLAGWAIT = (set(range(0x200D6, 0x200D9)) | set(range(0x200E6, 0x200EB)) |
               set(range(0x20BEB, 0x20BEE)) | set(range(0x20C22, 0x20C25)) |
               set(range(0x20C61, 0x20C64)))            # FLAG0_IN / DM(0x37) bit 6 polls


def stats(v):
    v = sorted(v)
    if not v:
        return None
    p95 = v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))]
    return v[0], statistics.median(v), p95, v[-1]


def fmt(x):
    if isinstance(x, float) and not x.is_integer():
        return f"{x:.3g}" if abs(x) < 10 else f"{x:.0f}"
    return f"{int(x)}"


def sharc_frames(run):
    out = {}
    for line in open(run / "pcs_sharc.txt"):
        parts = line.split()
        f = int(parts[0])
        c = Counter()
        for p in parts[1:]:
            a, n = p.split(":")
            a, n = int(a, 16), int(n)
            if a in SH_IDLE:
                c["idle"] += n
            elif a in SH_VWAIT:
                c["vwait"] += n
            elif a in SH_DMAWAIT:
                c["dmawait"] += n
            elif a in SH_FLAGWAIT:
                c["flagwait"] += n
            else:
                c["busy"] += n
        out[f] = c
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    a = ap.parse_args()
    run = Path(a.run)
    rows = list(csv.DictReader(open(run / "frames.csv")))
    sh = sharc_frames(run)
    by = defaultdict(list)
    for r in rows:
        by[r["phase"]].append(r)

    for ph in ("attract", "play"):
        rs = by[ph]
        if not rs:
            continue
        print(f"\n== {ph}: {len(rs)} frames ({rs[0]['frame']}-{rs[-1]['frame']})")
        drawn = sum(1 for r in rs if int(r["tri"]) + int(r["ftri"]) > 0)
        print(f"frames with triangles: {drawn}")
        cols = defaultdict(list)
        for r in rs:
            f = int(r["frame"])
            g = lambda k: float(r[k] or 0)
            cols["triangles"].append(g("tri") + g("ftri"))
            for k in ("ftri", "fastfill", "swap", "nop", "regw", "lfbw", "texw", "texsrc_r",
                      "tri_area", "tri_area_tex", "tri_area_blend", "tri_area_bilin", "tri_area_z",
                      "fastfill_px", "pin", "pout", "zfail", "afail", "chroma"):
                cols[k].append(g(k))
            cols["tex_bytes"].append(g("texw") * 4)
            cols["lfb_bytes"].append(g("lfbw") * 4)
            cols["ppc->sh bytes (PPC writes)"].append(g("ppc_sh_w"))
            cols["ppc<-sh bytes (PPC reads)"].append(g("ppc_sh_r"))
            cols["sharc shared reads (words)"].append(g("sh_sh_r"))
            cols["sharc shared writes (words)"].append(g("sh_sh_w"))
            cols["ppc comm w/r"].append(g("ppc_comm_w") + g("ppc_comm_r"))
            cols["sharc comm w/r"].append(g("sh_comm_w") + g("sh_comm_r"))
            cols["sharc resets"].append(g("sh_reset"))
            tot = g("ppc_idle") + g("ppc_work")
            if tot:
                cols["PPC busy %"].append(100 * g("ppc_work") / tot)
            c = sh.get(f)
            if c:
                t = sum(c.values())
                for k in ("busy", "idle", "vwait", "dmawait", "flagwait"):
                    cols[f"SHARC {k} %"].append(100 * c[k] / t)
        print(f"{'metric':32s} {'min':>9s} {'median':>9s} {'p95':>9s} {'max':>9s} {'mean':>9s}")
        for k, v in cols.items():
            s = stats(v)
            print(f"{k:32s} " + " ".join(f"{fmt(x):>9s}" for x in s) + f" {fmt(sum(v)/len(v)):>9s}")

        modes = run / f"modes_{ph}.txt"
        hist = defaultdict(Counter)
        for line in open(modes):
            key, val, n = line.rstrip("\n").split("\t")
            hist[key][val] += int(n)
        for key in sorted(hist):
            if key in ("tri_state", "tri_state_area", "regs_written"):
                continue
            items = hist[key].most_common(8)
            print(f"  {key}: " + ", ".join(f"{v}x{n}" for v, n in items))
        print("  triangle states (by count; area in px):")
        area = hist["tri_state_area"]
        for v, n in hist["tri_state"].most_common(12):
            print(f"    {n:7d} tris {area[v]:9d} px  {v}")
        decode(hist)


def decode(hist):
    """Feature summary from the per-triangle state keys."""
    feats = Counter()
    area = hist["tri_state_area"]
    tot = sum(area.values()) or 1
    fmts = Counter()
    for key, n in hist["tri_state"].items():
        f = dict(kv.split("=") for kv in key.split())
        cp, fz, am, fm, tm, tl = (int(f[k], 16) for k in ("cp", "fz", "am", "fm", "tm", "tlod"))
        px = area[key]
        tex = cp >> 27 & 1
        flags = {
            "textured": tex,
            "perspective": tex and tm & 1,
            "bilinear(min|mag)": tex and (tm >> 1) & 3 != 0,
            "mipmap(lodmin!=lodmax)": tex and (tl & 0x3f) != ((tl >> 6) & 0x3f),
            "clamp s/t": tex and (tm >> 6) & 3 != 0,
            "alpha blend": am >> 4 & 1,
            "alpha test": am & 1,
            "fog": fm & 1,
            "chroma key": fz >> 1 & 1,
            "depth buffer": fz >> 4 & 1,
            "w-buffer": fz >> 4 & 1 and fz >> 3 & 1,
            "dither": fz >> 8 & 1,
            "stipple": fz >> 2 & 1,
            "aux (depth/alpha) write": fz >> 10 & 1,
        }
        for k, v in flags.items():
            if v:
                feats[k] += px
        if tex:
            fmts[(tm >> 8) & 0xf] += px
    print("  features by share of triangle area:")
    for k, v in feats.most_common():
        print(f"    {k:26s} {100 * v / tot:5.1f}%")
    names = {0: "RGB332", 1: "YIQ422", 2: "A8", 3: "I8", 4: "AI44", 5: "P8", 8: "ARGB8332",
             9: "AYIQ8422", 10: "RGB565", 11: "ARGB1555", 12: "ARGB4444", 13: "AI88", 14: "AP88"}
    print("  texture formats by area: " + ", ".join(
        f"{names.get(k, k)} {100 * v / tot:.1f}%" for k, v in fmts.most_common()))


if __name__ == "__main__":
    main()
