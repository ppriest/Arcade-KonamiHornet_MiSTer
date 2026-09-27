#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Disassemble ranges of a CPU's address space with MAME's debugger, at a frame.

    python scripts/mame_dasm.py gradius4 --frame 150 80205D00:200 80209640:80 [--cpu maincpu]
    -> debug/<set>-dasm/dasm_<start>.txt
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, mame_paths, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("ranges", nargs="+", help="start:length, hex")
    ap.add_argument("--frame", type=int, default=150)
    ap.add_argument("--cpu", default="maincpu")
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-dasm"
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAME=str(a.frame), CORE_CPU=a.cpu,
               CORE_RANGES=",".join(a.ranges), CORE_SCRIPT=str(REPO / "scripts" / "mame" / "dasm.lua"))
    cmd = [str(exe), a.game, "-debug", "-debugger", "none", "-nowindow", "-video", "none",
           "-sound", "none", "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(REPO / "scripts" / "mame" / "run.lua"), "-rompath", rompath(mame_dir),
           "-nvram_directory", str(Path(a.nvram)), "-cfg_directory", str(out / "cfg")]
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    if "DASM_DONE" not in p.stdout:
        sys.exit("dasm did not finish:\n" + (p.stdout + p.stderr)[-2000:])
    for r in a.ranges:
        print(out / f"dasm_{r.split(':')[0]}.txt")


if __name__ == "__main__":
    main()
