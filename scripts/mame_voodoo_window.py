#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture the Voodoo's state and the SHARC's writes to it over N frames, for sim/voodoo_tb.

    python scripts/mame_voodoo_window.py gradius4 --frame 3000 [--frames 1] [--nvram debug/nvram]
        [--events 4400:IN2:80:5,4430:IN0:80:5] [--dip "Monitor Type=15KHz" --tag 15k]
    -> debug/<set>-voodoo<frame>[-<tag>]/{start/, writes.txt, end/}

start/ and end/ hold vitems.txt (the :voodoo0 save items) and fbram.bin (2 MB frame buffer,
then 4 MB of TMU memory). MAME runs -nodrc so the data-space taps see the SHARC's accesses.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--frame", type=int, required=True)
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="")
    ap.add_argument("--pokes", default="", help="from:addr:value,... bytes written every frame (cheats)")
    ap.add_argument("--dip", default="", help='"Field=Setting;...", e.g. "Monitor Type=15KHz"')
    ap.add_argument("--tag", default="", help="output folder suffix, -<tag>")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / (f"{a.game}-voodoo{a.frame}" + (f"-{a.tag}" if a.tag else ""))
    out.mkdir(parents=True, exist_ok=True)
    for c in out.iterdir():               # clear, not remove: the folder may be a cwd
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    (out / "cfg").mkdir()
    if Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAME=str(a.frame), CORE_FRAMES=str(a.frames),
               CORE_EVENTS=a.events, CORE_POKES=a.pokes, CORE_DIPS=a.dip,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "voodoowin.lua"))
    cmd = mame_cmd(exe, a.game, None, mame_dir,
                   ["-nodrc", "-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg"),
                    "-seconds_to_run", str(a.frame // 50 + a.frames + 60)])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    (out / "mame_log.txt").write_text(p.stdout + p.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if "VOODOOWIN_DONE" not in p.stdout:
        sys.exit("capture did not finish:\n" + (p.stdout + p.stderr)[-2000:])
    n = sum(1 for l in open(out / "writes.txt") if l[0] in "WR")
    print(f"{n} Voodoo accesses over {a.frames} frame(s) -> {out}")


if __name__ == "__main__":
    main()
