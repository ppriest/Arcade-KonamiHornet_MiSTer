#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Every distinct SHARC program over a long run (scripts/mame/sharc_pm_versions.lua), for the
core's instruction subset (docs/ROADMAP.md, "Area plan"). A play run with --cheats reaches the later
stages (MAME's Invincibility and Infinite Lives).

    python scripts/mame_sharc_pm_versions.py gradius4 --to 30000 --name attract
    python scripts/mame_sharc_pm_versions.py gradius4 --to 60000 --name play \
        --events 4400:IN2:80:5,4430:IN0:80:5 --cheats 8021708b:18,4930:09 --cheat-from 4500
    -> debug/<set>-pmversions-<name>/: versions.txt, pm_<frame>.bin, snap_<frame>.png
    python scripts/sharc_census.py debug/<set>-pmversions-<name> --pm pm_<frame>.bin
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
    ap.add_argument("--to", type=int, default=30000)
    ap.add_argument("--every", type=int, default=50)
    ap.add_argument("--name", default="run")
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="")
    ap.add_argument("--cheats", default="")
    ap.add_argument("--cheat-from", type=int, default=0)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-pmversions-{a.name}"
    out.mkdir(parents=True, exist_ok=True)
    for c in out.iterdir():
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    (out / "cfg").mkdir()
    if Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_TO=str(a.to), CORE_EVERY=str(a.every),
               CORE_EVENTS=a.events, CORE_CHEATS=a.cheats, CORE_CHEAT_FROM=str(a.cheat_from),
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "sharc_pm_versions.lua"))
    cmd = mame_cmd(exe, a.game, None, mame_dir,
                   ["-nodrc", "-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg"),
                    "-snapshot_directory", str(out), "-seconds_to_run", str(a.to // 50 + 60)])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    (out / "mame_log.txt").write_text(p.stdout + p.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if "PMVERSIONS_DONE" not in p.stdout:
        sys.exit("run did not finish:\n" + (p.stdout + p.stderr)[-2000:])
    print(f"-> {out}")
    print((out / "versions.txt").read_text())


if __name__ == "__main__":
    main()
