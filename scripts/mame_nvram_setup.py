#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The M48T58 bytes Gradius IV's first boot writes, for the .mra's <patch> (scripts/gen_mra.py).

    python scripts/mame_nvram_setup.py [set ...]

MAME's NVRAM images are hand-built (BAD_DUMP) and fail the game's RTC checksum. Per set, MAME runs
the first boot from the set's image: "RTC CHECKSUM ERROR" -> Test; ADJUST SYSTEM CLOCK (difference)
-> SAVE AND EXIT; ADJUST SYSTEM CLOCK (date) -> SAVE AND EXIT -> YES; the test menu -> GAME MODE.
That boot writes the factory settings at 0x10-0x7F and, once in game mode, a counter at
0x640-0x643; anything else written below the clock registers (0x1FF8) stops the script. 0x10-0x7F
go to scripts/m48t58_setup.json. A second boot from the set's image with those bytes is checked to
reach game mode (it writes 0x640-0x643, which no run stopped at a setup screen did); its frames are
in debug/nvram-setup/<set>/sheet.png.
"""
import json
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from gen_mra import SETS  # noqa: E402
from mame_capture import load_env  # noqa: E402
import rom_images  # noqa: E402

OUT = REPO / "debug" / "nvram-setup"
JSON = REPO / "scripts" / "m48t58_setup.json"
LO, HI = 0x10, 0x80                     # the settings the patch carries
COUNTER = range(0x640, 0x644)
CLOCK = 0x1FF8


def press(frame, port, mask):
    return f"{frame}:{port}:{mask}:8"


# IN2 0x10 Test; IN0 0x80 Start, 0x40 up, 0x20 down, 0x10 left (hornet.cpp's ports)
EVENTS = (["1300:IN2:10:10"]
          + [press(f, "IN0", 20) for f in (1500, 1560, 1620)] + [press(1700, "IN0", 80)]
          + [press(f, "IN0", 20) for f in range(2100, 2401, 60)] + [press(2500, "IN0", 80)]
          + [press(2600, "IN0", 10), press(2700, "IN0", 80)]
          + [press(2900, "IN0", 40), press(3000, "IN0", 80)])
SNAPS_SETUP = [1250, 1680, 2450, 2650, 2950, 3100, 3600, 4400]
SNAPS_BOOT = [600, 1000, 1300, 1700, 2200, 2800, 3400, 4000]


def run(out, setname, snaps, end, events=(), nvram=None):
    if out.exists():
        shutil.rmtree(out)
    cmd = [sys.executable, str(REPO / "scripts" / "hornet_load.py"), "--set", setname, "--out", str(out),
           "--snaps", ",".join(map(str, snaps)), "--end", str(end)]
    if events:
        cmd += ["--events", ",".join(events)]
    if nvram:
        cmd += ["--nvram", str(nvram)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"{setname}: {p.stdout}{p.stderr}")
    shots = [Image.open(out / "snap" / setname / f"{i:04d}.png").resize((256, 192)) for i in range(len(snaps))]
    sheet = Image.new("RGB", (256 * 4, 192 * 2))
    for i, im in enumerate(shots):
        sheet.paste(im, ((i % 4) * 256, (i // 4) * 192))
    sheet.save(out / "sheet.png")
    return (out / "nvram" / setname / "m48t58").read_bytes()


def one(setname, romdir):
    s = {**SETS.get(SETS[setname].get("parent"), {}), **SETS[setname]}
    image = rom_images.SetZips(romdir, setname).read(s["nv"])
    first = run(OUT / f"{setname}-first", setname, SNAPS_SETUP, 4500, EVENTS)
    stray = [hex(i) for i in range(CLOCK) if first[i] != image[i] and not (LO <= i < HI or i in COUNTER)]
    if stray:
        sys.exit(f"{setname}: the first boot also wrote {stray}")
    patched = bytearray(image)
    patched[LO:HI] = first[LO:HI]
    nv = OUT / f"{setname}-nvram"
    if nv.exists():
        shutil.rmtree(nv)
    (nv / setname).mkdir(parents=True)
    (nv / setname / "m48t58").write_bytes(patched)
    second = run(OUT / setname, setname, SNAPS_BOOT, 4100, nvram=nv)
    if all(second[i] == patched[i] for i in COUNTER):
        sys.exit(f"{setname}: the second boot did not reach game mode ({OUT / setname / 'sheet.png'})")
    return setname, first[LO:HI].hex(" ")


def main():
    romdir = Path(load_env()["MAME_ROMPATH"].split(";")[0])
    names = sys.argv[1:] or [n for n, s in SETS.items() if n == "gradius4" or s.get("parent") == "gradius4"]
    table = json.loads(JSON.read_text())["sets"] if JSON.exists() else {}
    with ThreadPoolExecutor(3) as ex:
        for name, data in ex.map(lambda n: one(n, romdir), names):
            table[name] = data
            print(f"{name}: second boot reached game mode; {OUT / name / 'sheet.png'}")
    JSON.write_text(json.dumps({"at": f"{LO:#x}", "sets": dict(sorted(table.items()))}, indent=1) + "\n")
    print(f"-> {JSON}")


if __name__ == "__main__":
    main()
