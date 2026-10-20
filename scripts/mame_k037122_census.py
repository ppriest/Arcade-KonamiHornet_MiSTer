#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Census of the K037122 SRAM over a long run: the quarters the PPC reads and writes, and the
control register's values, to size the core's SRAM.

    python scripts/mame_k037122_census.py gradius4 --to 30000 --name attract
    python scripts/mame_k037122_census.py gradius4 --to 9000 --name play --events 4400:IN2:80:5,4430:IN0:80:5
    -> debug/<set>-kscensus-<name>/kscensus.txt
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
    ap.add_argument("--name", default="run")
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-kscensus-{a.name}"
    out.mkdir(parents=True, exist_ok=True)
    for c in out.iterdir():
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    (out / "cfg").mkdir()
    if Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_TO=str(a.to), CORE_EVENTS=a.events,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "k037122_census.lua"))
    cmd = mame_cmd(exe, a.game, None, mame_dir,
                   ["-nodrc", "-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg"),
                    "-seconds_to_run", str(a.to // 50 + 60)])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    (out / "mame_log.txt").write_text(p.stdout + p.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if "KSCENSUS_DONE" not in p.stdout:
        sys.exit("census did not finish:\n" + (p.stdout + p.stderr)[-2000:])
    print(f"census -> {out / 'kscensus.txt'}")


if __name__ == "__main__":
    main()
