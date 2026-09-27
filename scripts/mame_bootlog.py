#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Log the PPC's device accesses from power-on, by frame (scripts/mame/bootlog.lua).

    python scripts/mame_bootlog.py gradius4 [--to 800]
    -> debug/<set>-bootlog/bootlog.txt
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
    ap.add_argument("--to", type=int, default=800)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-bootlog"
    out.mkdir(parents=True, exist_ok=True)
    for c in out.iterdir():
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    (out / "cfg").mkdir()
    if Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAMES=str(a.to), CORE_EVENTS=a.events,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "bootlog.lua"))
    cmd = mame_cmd(exe, a.game, None, mame_dir,
                   ["-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg"),
                    "-seconds_to_run", str(a.to // 50 + 60)])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    (out / "mame_log.txt").write_text(p.stdout + p.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if "BOOTLOG_DONE" not in p.stdout:
        sys.exit("scan did not finish:\n" + (p.stdout + p.stderr)[-2000:])

    print(f"-> {out}/bootlog.txt")


if __name__ == "__main__":
    main()
