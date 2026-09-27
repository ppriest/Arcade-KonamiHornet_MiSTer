#!/usr/bin/env python3
"""Profile gradius4's use of the SHARC (:dsp1) in MAME: internal RAM footprint, external
accesses per frame, interrupts, IOP/DMA writes, sampled modes, and a dsp1 debugger trace per
window for the instruction mix. Runs scripts/mame/sharc_profile.lua with -nodrc -debug.
Summarise with scripts/sharc_profile_report.py.

Example (the defaults):
  python scripts/sharc_profile.py --out D:/tmp/sharc --nvram debug/nvram
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUA = REPO / "scripts" / "mame"
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import mame_paths, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="gradius4")
    ap.add_argument("--out", required=True)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"))
    ap.add_argument("--events", default="4400:IN2:80:5,4430:IN0:80:5")
    ap.add_argument("--windows", default="attract:2800:3400,demo:1900:2300,play:7000:7600")
    ap.add_argument("--play", default="4500:7600", help="frames in which controls are driven")
    ap.add_argument("--traces", default="attract:3000:4,demo:2150:4,play:7500:4",
                    help="name:frame:nframes of dsp1 debugger trace")
    ap.add_argument("--end", type=int, default=7601)
    ap.add_argument("--sr", type=int, default=20000)
    ap.add_argument("--snaps", default="2100,3000,7300,7550")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = Path(a.out)
    if out.exists():
        shutil.rmtree(out)
    (out / "cfg").mkdir(parents=True)
    (out / "snap").mkdir()
    shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_SCRIPT=str(LUA / "sharc_profile.lua"),
               CORE_EVENTS=a.events, CORE_WINDOWS=a.windows, CORE_PLAY=a.play,
               CORE_TRACES=a.traces, CORE_END=str(a.end), CORE_SR=str(a.sr), CORE_SNAPS=a.snaps)
    cmd = [str(exe), a.set, "-debug", "-debugger", "none", "-nodrc", "-nowindow", "-video", "none",
           "-sound", "none", "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(LUA / "run.lua"), "-rompath", rompath(mame_dir),
           "-snapshot_directory", str(out / "snap"), "-nvram_directory", str(out / "nvram"),
           "-cfg_directory", str(out / "cfg")]
    print(" ".join(f'"{c}"' if " " in c else c for c in cmd))
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True)
    blob = p.stdout + p.stderr
    (out / "mame_log.txt").write_text(blob)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text().strip())
    if "SHARC_PROFILE_OK" not in blob:
        sys.exit("run did not complete:\n" + "\n".join(blob.strip().splitlines()[-15:]))
    print((out / "heartbeat.txt").read_text().strip().splitlines()[-1])


if __name__ == "__main__":
    main()
