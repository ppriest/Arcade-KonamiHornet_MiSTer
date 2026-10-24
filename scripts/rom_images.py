#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Flat big-endian images of a Hornet set's regions, as MAME builds them.

    python scripts/rom_images.py [gradius4]  ->  debug/<set>-roms/{prgrom,datarom,cgrom}.bin

A clone is its parent's entry with its own files (SETS "parent"); its files are read from its own
zip, else the parent's (a merged parent zip keeps them under "<clone>/").

prgrom: ROM_LOAD16_WORD_SWAP at 0x200000, reloaded at 0 (hornet.cpp:2874-2876).
datarom: ROM_LOAD32_WORD_SWAP, a04 in bytes 0-1 and a05 in bytes 2-3 of each word
(hornet.cpp:2878-2879). cgrom: ROM_LOAD32_WORD_SWAP, a13/a15 in bytes 0-1 and a14/a16 in
bytes 2-3, the second pair at 8 MB (hornet.cpp:2881-2885).
"""
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402

SETS = {
    "gradius4": {"prg": "837c01.27p", "data": ("837a04.16t", "837a05.14t"),
                 "cg": (("837a13.24u", "837a14.32u"), ("837a15.24v", "837a16.32v"))},
    "nbapbp": {"prg": "778b01.27p", "data": ("778a04.16t", "778a05.14t"),
               "cg": (("778a13.24u", "778a14.32u"), ("778a15.24v", "778a16.32v"))},
    # clones (MAME 0.289 -listclones gradius4): their program ROM; the rest is the parent's
    "gradius4a": {"parent": "gradius4", "prg": "837c01.27p"},
    "gradius4u": {"parent": "gradius4", "prg": "837c01.27p"},
    "gradius4aa": {"parent": "gradius4", "prg": "837a01.27p"},
    "gradius4ja": {"parent": "gradius4", "prg": "837a01.27p"},
    "gradius4ua": {"parent": "gradius4", "prg": "837a01.27p"},
}


def entry(name):
    """A set's entry, a clone's merged over its parent's."""
    s = SETS[name]
    return {**SETS[s["parent"]], **s} if "parent" in s else dict(s)


class SetZips:
    """A set's files by name: its own zip, then its parent's; in a merged parent zip a clone's
    files are under "<clone>/", tried before the parent's own."""
    def __init__(self, romdir, name):
        s = SETS[name]
        self.name = name
        self.paths = [p for p in (romdir / f"{name}.zip", romdir / f"{s.get('parent', name)}.zip") if p.exists()]
        self.paths = list(dict.fromkeys(self.paths))
        if not self.paths:
            raise FileNotFoundError(f"no zip for {name} in {romdir}")
        self.zips = [zipfile.ZipFile(p) for p in self.paths]

    def info(self, fname):
        for z in self.zips:
            for n in (f"{self.name}/{fname}", fname):
                try:
                    return z, z.getinfo(n)
                except KeyError:
                    pass
        # a dump two clones share is stored once, under the first clone's folder
        for z in self.zips:
            for i in z.infolist():
                if i.filename.endswith("/" + fname):
                    return z, i
        raise KeyError(f"{fname} not in {', '.join(str(p) for p in self.paths)}")

    def read(self, fname):
        z, i = self.info(fname)
        return z.read(i)

    def crc(self, fname):
        return f"{self.info(fname)[1].CRC:08x}"

    def size(self, fname):
        return self.info(fname)[1].file_size


def swap16(b):
    out = bytearray(len(b))
    out[0::2], out[1::2] = b[1::2], b[0::2]
    return bytes(out)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "gradius4"
    s = entry(name)
    romdir = Path(load_env().get("MAME_ROMPATH", "")).expanduser()
    z = SetZips(romdir, name)
    out = REPO / "debug" / f"{name}-roms"
    out.mkdir(parents=True, exist_ok=True)

    def words32(hi_name, lo_name, size):
        hi, lo = swap16(z.read(hi_name)), swap16(z.read(lo_name))
        img = bytearray(size)
        for i in range(len(hi) // 2):
            img[4 * i:4 * i + 2] = hi[2 * i:2 * i + 2]
            img[4 * i + 2:4 * i + 4] = lo[2 * i:2 * i + 2]
        return img

    prg = swap16(z.read(s["prg"]))
    (out / "prgrom.bin").write_bytes(prg + prg)

    data = words32(*s["data"], 8 * 1024 * 1024)
    (out / "datarom.bin").write_bytes(bytes(data))

    cg = bytearray(16 * 1024 * 1024)
    for half, (f_hi, f_lo) in enumerate(s["cg"]):
        hi, lo = swap16(z.read(f_hi)), swap16(z.read(f_lo))
        base = half * 8 * 1024 * 1024
        for i in range(len(hi) // 2):
            cg[base + 4 * i:base + 4 * i + 2] = hi[2 * i:2 * i + 2]
            cg[base + 4 * i + 2:base + 4 * i + 4] = lo[2 * i:2 * i + 2]
    (out / "cgrom.bin").write_bytes(bytes(cg))
    print(f"{out}: prgrom {len(prg) * 2:#x}, datarom {len(data):#x}")


if __name__ == "__main__":
    main()
