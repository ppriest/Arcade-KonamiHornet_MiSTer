#!/usr/bin/env python3
"""Run gradius4 in MAME under scripts/mame/hornet_load.lua and write the raw
per-frame workload data to --out. Summarise with hornet_load_report.py.

Example:
  python scripts/hornet_load.py --out D:/tmp/g4 --events 1300:IN2:10:10 \
      --attract 2000:3999 --play 4300:6400 --end 6400 --snaps 3000,5000,6000
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

_MAME_DIR, MAME = mame_paths()
ROMS = rompath(_MAME_DIR)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="gradius4")
    ap.add_argument("--out", required=True)
    ap.add_argument("--events", default="", help="frame:port:hexmask:len,...")
    ap.add_argument("--snaps", default="")
    ap.add_argument("--attract", default="")
    ap.add_argument("--play", default="")
    ap.add_argument("--end", type=int, default=3000)
    ap.add_argument("--sr", type=int, default=20000, help="PC sample rate, Hz")
    ap.add_argument("--stats", action="store_true", help="read Voodoo pixel counters each frame")
    ap.add_argument("--nodrc", action="store_true", help="interpreted CPU cores")
    ap.add_argument("--nvram", default=None,
                    help="directory holding <set>/ NVRAM to start from (copied, not modified); "
                         "without it gradius4 stops at the RTC checksum error")
    ap.add_argument("--dasm", default="",
                    help='debugger commands at a frame, "frame|cmd|cmd,frame|..."; use ";" '
                         'for the commas inside a command. Files land in the MAME directory.')
    a = ap.parse_args()

    out = Path(a.out)
    for sub in ("snap", "nvram", "cfg"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.txt"):
        f.unlink()
    if a.nvram:
        shutil.rmtree(out / "nvram")
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_SCRIPT=str(LUA / "hornet_load.lua"),
               CORE_EVENTS=a.events, CORE_SNAPS=a.snaps, CORE_ATTRACT=a.attract,
               CORE_PLAY=a.play, CORE_END=str(a.end), CORE_SR=str(a.sr),
               CORE_STATS="1" if a.stats else "0", CORE_DASM=a.dasm)
    cmd = [str(MAME), a.set, "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
           "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(LUA / "run.lua"), "-rompath", ROMS,
           "-snapshot_directory", str(out / "snap"), "-nvram_directory", str(out / "nvram"),
           "-cfg_directory", str(out / "cfg"), "-seconds_to_run", str(a.end // 50 + 30)]
    if a.nodrc:
        cmd.append("-nodrc")
    if a.dasm:
        cmd[2:3] = ["-debug", "-debugger", "none"]
    print(" ".join(f'"{c}"' if " " in c else c for c in cmd))
    p = subprocess.run(cmd, cwd=MAME.parent, env=env, capture_output=True, text=True)
    blob = p.stdout + p.stderr
    (out / "mame_log.txt").write_text(blob)
    err = out / "lua_error.txt"
    if err.exists():
        sys.exit("Lua failed: " + err.read_text().strip())
    if "HORNET_LOAD_OK" not in blob:
        sys.exit("run did not complete:\n" + "\n".join(blob.strip().splitlines()[-15:]))
    print("\n".join(l for l in blob.splitlines() if "Average speed" in l))


if __name__ == "__main__":
    main()
