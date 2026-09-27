#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Log the K037122's scroll, increment and control registers per frame, and list the frames that
rotate or zoom its tilemap.

    python scripts/mame_k037122_scan.py gradius4 [--to 4400] [--events ...]
    -> debug/<set>-k037122scan/k037122.txt ("frame r20 r24 r28 r30 r34", on change)
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
    ap.add_argument("--to", type=int, default=4400)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-k037122scan"
    out.mkdir(parents=True, exist_ok=True)
    for c in out.iterdir():
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    (out / "cfg").mkdir()
    if Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAMES=str(a.to), CORE_EVENTS=a.events,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "k037122scan.lua"))
    cmd = mame_cmd(exe, a.game, None, mame_dir,
                   ["-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg"),
                    "-seconds_to_run", str(a.to // 50 + 60)])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    (out / "mame_log.txt").write_text(p.stdout + p.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if "K037122SCAN_DONE" not in p.stdout:
        sys.exit("scan did not finish:\n" + (p.stdout + p.stderr)[-2000:])

    runs, cur = [], None
    for line in open(out / "k037122.txt"):
        f, r20, r24, r28, r30, r34 = line.split()
        f, r24, r28 = int(f), int(r24, 16), int(r28, 16)
        incxx, incxy, incyx, incyy = r28 >> 16, r28 & 0xffff, r24 >> 16, r24 & 0xffff
        roz = (incxy, incyx) != (0, 0) or (incxx, incyy) != (0x1000, 0x1000)
        if roz and cur is None:
            cur = [f, f, line.split()[1:]]
        elif roz:
            cur[1] = f
        elif cur is not None:
            runs.append(cur); cur = None
    if cur is not None:
        runs.append(cur)
    for f0, f1, regs in runs:
        print(f"rotated/zoomed from frame {f0} (last change {f1}): {' '.join(regs)}")
    if not runs:
        print("no frame rotates or zooms the K037122 tilemap")


if __name__ == "__main__":
    main()
