#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Flat big-endian images of a Hornet set's regions, as MAME builds them.

    python scripts/rom_images.py [gradius4]  ->  debug/<set>-roms/{prgrom,datarom,cgrom}.bin

prgrom: ROM_LOAD16_WORD_SWAP at 0x200000, reloaded at 0 (hornet.cpp:2874-2876).
datarom: ROM_LOAD32_WORD_SWAP, a04 in bytes 0-1 and a05 in bytes 2-3 of each word
(hornet.cpp:2878-2879). cgrom: ROM_LOAD32_WORD_SWAP, a13/a15 in bytes 0-1 and a14/a16 in
bytes 2-3, the second pair at 8 MB (hornet.cpp:2881-2885). Only gradius4 is described so far.
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
}


def swap16(b):
    out = bytearray(len(b))
    out[0::2], out[1::2] = b[1::2], b[0::2]
    return bytes(out)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "gradius4"
    s = SETS[name]
    romdir = Path(load_env().get("MAME_ROMPATH", "")).expanduser()
    z = zipfile.ZipFile(romdir / f"{name}.zip")
    out = REPO / "debug" / f"{name}-roms"
    out.mkdir(parents=True, exist_ok=True)

    prg = swap16(z.read(s["prg"]))
    (out / "prgrom.bin").write_bytes(prg + prg)

    hi, lo = (swap16(z.read(f)) for f in s["data"])
    data = bytearray(8 * 1024 * 1024)
    for i in range(len(hi) // 2):
        data[4 * i:4 * i + 2] = hi[2 * i:2 * i + 2]
        data[4 * i + 2:4 * i + 4] = lo[2 * i:2 * i + 2]
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
