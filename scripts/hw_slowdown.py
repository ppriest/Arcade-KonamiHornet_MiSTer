#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Count the slowdown indicator in a run of screenshots from the MiSTer.

    python scripts/hw_slowdown.py capture <seconds> <out dir>    # a native shot a second, fetched to out dir
    python scripts/hw_slowdown.py count <out dir>                # shots showing the square, in order

The indicator (KonamiHornet.sv `ind_on`, OSD "Slowdown indicator" On) is a yellow 8x8 square at the
picture's top-right corner, shown for 30 frames after a buffer swap two to fifteen frames after the
last, or a tilemap line shown before it was built. A native screenshot (/dev/MiSTer_cmd) is the
core's frame, so the square is the top-right 8x8 of the image.
"""
import subprocess
import sys
import tarfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from hw import REMOTE_SHOTS, Mister, load_env  # noqa: E402


def capture(seconds, out):
    m = Mister(load_env(REPO, require=("MISTER_HOST", "MISTER_USER", "MISTER_PASSWORD")))
    core = m.core_name()
    d = f"{REMOTE_SHOTS}/{core}"
    m.sh(f"mkdir -p {d}; rm -f {d}/*.png", check=False)
    m.sh(f"nohup sh -c 'for i in $(seq 1 {seconds}); do echo screenshot > /dev/MiSTer_cmd; sleep 1; done' >/dev/null 2>&1 &", check=False)
    time.sleep(seconds + 5)
    fetch(m, d, out)


def fetch(m, d, out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    m.sh(f"cd {d} && tar cf /tmp/shots.tar *.png", check=False)
    m.get_file("/tmp/shots.tar", out / "shots.tar")
    with tarfile.open(out / "shots.tar") as t:
        t.extractall(out, filter="data")
    (out / "shots.tar").unlink()
    print(f"{len(list(out.glob('*.png')))} shots -> {out}")


def count(out):
    from PIL import Image
    shots = sorted(Path(out).glob("*.png"))
    on = []
    for p in shots:
        try:
            im = Image.open(p).convert("RGB")
        except OSError:
            continue                   # still being written when fetched
        w, h = im.size
        # the core's frame: the square is the top-right 8x8; a scaled shot keeps the corner
        px = [im.getpixel((w - 1 - x, y)) for x in range(2, 6) for y in range(2, 6)]
        if all(r > 200 and g > 200 and b < 80 for r, g, b in px):
            on.append(p.name)
    print(f"{len(on)} of {len(shots)} shots show the indicator ({shots[0].name if shots else ''} .. {shots[-1].name if shots else ''})")
    for n in on:
        print("  " + n)
    return on


def main():
    if sys.argv[1] == "capture":
        capture(int(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == "count":
        count(sys.argv[2])


if __name__ == "__main__":
    main()
