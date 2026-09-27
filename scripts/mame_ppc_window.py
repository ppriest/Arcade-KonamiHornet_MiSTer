#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture a window of PPC403 execution from MAME for sim/ppc_tb to replay and diff.

    python scripts/mame_ppc_window.py gradius4 --frame 3000 --n 2000000 [--nvram debug/nvram]
        [--events 4400:IN2:80:5,4430:IN0:80:5]
    -> debug/<set>-win<frame>/{state.txt, workram.bin, trace.tr, io.txt}

Then:  scripts/run_verilator.sh ppc_tb +win=debug/<set>-win<frame> +n=<N>
       python scripts/compare_insn_trace.py <set> --dir debug/<set>-win<frame>

The trace is the debugger's (state before each instruction, no loop suppression); io.txt is
every PPC access outside work RAM and ROM, in bus order, which the bench replays for reads.
MAME runs with -debug, far slower than real time; the run is stopped by trace line count.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, mame_paths, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--frame", type=int, required=True)
    ap.add_argument("--n", type=int, default=1000000, help="trace lines to keep")
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram"),
                    help="directory holding <set>/ NVRAM (copied); gradius4 needs its RTC set up")
    ap.add_argument("--events", default="")
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-win{a.frame}"
    if out.exists():
        shutil.rmtree(out)
    (out / "cfg").mkdir(parents=True)
    if a.nvram and Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAME=str(a.frame), CORE_EVENTS=a.events,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "ppcwin.lua"))
    cmd = [str(exe), a.game, "-debug", "-debugger", "none", "-nowindow", "-video", "none",
           "-sound", "none", "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(REPO / "scripts" / "mame" / "run.lua"), "-rompath", rompath(mame_dir),
           "-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg")]
    p = subprocess.Popen(cmd, cwd=mame_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         **NO_WINDOW)
    tr = out / "trace.tr"
    t0, have = time.time(), 0
    while p.poll() is None and time.time() - t0 < a.timeout:
        time.sleep(2)
        if tr.exists():
            with open(tr, "rb") as f:
                have = sum(1 for _ in f)
            if have >= a.n:
                break
    if p.poll() is None:
        p.kill()
        p.wait()
    log = p.stdout.read().decode(errors="replace")
    (out / "mame_log.txt").write_text(log)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if not tr.exists():
        sys.exit("no trace written:\n" + log[-2000:])
    print(f"{min(have, a.n)} trace lines, {sum(1 for _ in open(out / 'io.txt'))} device accesses -> {out}")


if __name__ == "__main__":
    main()
