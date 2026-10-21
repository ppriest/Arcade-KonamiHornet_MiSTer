#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Log the sound board's traffic in MAME (scripts/mame/sndlog.lua) and record its output.

    python scripts/mame_sndlog.py gradius4 [--frame 0] [--frames 600] [--events 4400:IN2:80:5,...]
    -> debug/<set>-sndlog<frame>/{sndlog.txt, sound.wav}

The wav covers the whole run from power-on; sndlog.txt's F lines give the frames' times.
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
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-sndlog{a.frame}"
    out.mkdir(parents=True, exist_ok=True)
    for c in out.iterdir():
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    (out / "cfg").mkdir()
    if Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAME=str(a.frame), CORE_FRAMES=str(a.frames), CORE_EVENTS=a.events,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "sndlog.lua"))
    cmd = mame_cmd(exe, a.game, None, mame_dir,
                   ["-nodrc", "-wavwrite", str(out / "sound.wav"), "-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg"),
                    "-seconds_to_run", str((a.frame + a.frames) // 50 + 60)])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    (out / "mame_log.txt").write_text(p.stdout + p.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if "SNDLOG_DONE" not in p.stdout:
        sys.exit("scan did not finish:\n" + (p.stdout + p.stderr)[-2000:])

    print(f"-> {out}/sndlog.txt")


if __name__ == "__main__":
    main()
