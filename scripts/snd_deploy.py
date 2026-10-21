#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the sound server (sw/arcsnd) for the MiSTer and install it.

    python scripts/snd_deploy.py [--no-install] [--package]

Cross-compiles with WSL's arm-linux-gnueabihf-gcc/g++ (static). Installs
/media/fat/games/arcsnd/arcsnd; Scripts/arcsnd.sh, which starts or stops it from the Scripts menu
(`start` at boot from linux/user-startup.sh); and, per Hornet set, games/<set>/_handler.sh, which
MiSTer Frontier's Master_Daemon.sh runs while that set is loaded (/tmp/CORENAME is the .mra's
setname). --package writes releases/arcsnd_<YYYYMMDD>.zip, the files where they go under
/media/fat.
"""
import argparse
import subprocess
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import load_env  # noqa: E402
from hw import Mister, REPO  # noqa: E402

SRC = REPO / "sw" / "arcsnd"
OBJ = REPO / "obj_arcsnd" / "arm"
ARCH = "-O3 -marm -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"
CXX = f"-std=c++17 {ARCH} -Wall -Wno-sign-compare -Icommon"
C_SRC = ["hornet/musashi/m68kcpu.c", "hornet/musashi/m68kops.c", "hornet/musashi/m68kdasm.c",
         "hornet/musashi/softfloat/softfloat.c"]
CXX_SRC = ["server.cpp", "common/daemon.cpp", "common/logerror.cpp",
           "hornet/board.cpp", "hornet/rf5c400.cpp", "hornet/session.cpp",
           "hng64/nec_core.cpp", "hng64/v53.cpp", "hng64/l7a1045.cpp", "hng64/board.cpp", "hng64/session.cpp"]
SETS = ["gradius4", "gradius4u", "gradius4a", "gradius4ja", "gradius4ua", "gradius4aa",
        "nbapbp", "nbapbpa", "nbapbpj", "nbapbpua", "nbapbpaa", "nbapbpja", "nbaatw", "nbaatwa"]
REMOTE_DIR = "/media/fat/games/arcsnd"
REMOTE_START = "/media/fat/Scripts/arcsnd.sh"

HANDLER = """#!/bin/sh
# Hornet sound: the sound board on the ARM (sw/arcsnd). MiSTer Frontier's Master_Daemon.sh runs
# this while the set is loaded and kills it when the core changes.
cd {dir} || exit 1
chmod +x arcsnd
exec ./arcsnd -v 2>/tmp/arcsnd.log
"""

START = """#!/bin/sh
# arcsnd: arcade sound boards on the ARM (Konami Hornet, Hyper NeoGeo 64), in the background. It
# waits for a set it knows, goes quiet at every core load, and runs as one copy.
#   (no argument)  from the Scripts menu: stop it if it is running, else start it
#   start          start it if it is not running (linux/user-startup.sh's $1 at boot)
#   stop           stop it
DIR={dir}
LOG=/tmp/arcsnd.log
running() {{ pidof arcsnd >/dev/null; }}
launch() {{ cd "$DIR" || exit 1; chmod +x arcsnd; setsid ./arcsnd -v </dev/null >/dev/null 2>"$LOG" & }}
halt() {{ kill $(pidof arcsnd); sleep 1; if running; then echo "arcsnd did not stop"; exit 1; fi; echo "arcsnd stopped"; }}
case "$1" in
start) running || launch ;;
stop) if running; then halt; fi ;;
*)
	if running; then echo "arcsnd is running: stopping it"; halt; exit 0; fi
	echo "starting arcsnd"; launch; sleep 3
	if running; then echo "arcsnd started"; else echo "arcsnd failed to start:"; tail -n 5 "$LOG"; exit 1; fi
	;;
esac
"""


def wsl_path(p):
    p = Path(p).resolve()
    return f"/mnt/{p.drive[0].lower()}{p.as_posix()[2:]}"


def wsl(cmds):
    r = subprocess.run(["wsl.exe", "-e", "bash", "-lc", " && ".join(cmds)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"build failed:\n{r.stdout}{r.stderr}")


def build(out):
    o = wsl_path(OBJ)
    cmds = [f"cd {wsl_path(SRC)}", f"mkdir -p {o}"]
    objs = []
    for s in C_SRC:
        obj = f"{o}/{Path(s).stem}.o"
        cmds.append(f"arm-linux-gnueabihf-gcc {ARCH} -Ihornet/musashi -c {s} -o {obj}")
        objs.append(obj)
    for s in CXX_SRC:
        obj = f"{o}/{s.replace('/', '_')[:-4]}.o"
        cmds.append(f"arm-linux-gnueabihf-g++ {CXX} -c {s} -o {obj}")
        objs.append(obj)
    cmds.append(f"arm-linux-gnueabihf-g++ {ARCH} -static -o {wsl_path(out)} " + " ".join(objs))
    wsl(cmds)


def put(m, local, remote):
    p = subprocess.run([m.pscp, "-batch", "-pw", m.pw, str(local), f"{m.user}@{m.host}:{remote}"],
                       capture_output=True, text=True, timeout=600)
    if p.returncode != 0:
        sys.exit(f"upload failed: {local}\n{p.stderr.strip()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", action="store_true", help="write releases/arcsnd_<YYYYMMDD>.zip")
    ap.add_argument("--no-install", action="store_true", help="build (and package) only")
    a = ap.parse_args()
    OBJ.mkdir(parents=True, exist_ok=True)
    binary = OBJ / "arcsnd"
    build(binary)
    start = OBJ / "arcsnd.sh"
    start.write_bytes(START.format(dir=REMOTE_DIR).encode())
    if a.package:
        out = REPO / "releases" / f"arcsnd_{time.strftime('%Y%m%d')}.zip"
        with zipfile.ZipFile(out, "w") as z:
            for path, data in ((REMOTE_DIR + "/arcsnd", binary.read_bytes()), (REMOTE_START, start.read_bytes())):
                zi = zipfile.ZipInfo(path.removeprefix("/media/fat/"), time.localtime()[:6])
                zi.create_system = 3
                zi.external_attr = 0o100755 << 16
                zi.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(zi, data)
        print(f"-> {out}")
    if a.no_install:
        print(f"-> {binary}")
        return 0
    m = Mister(load_env())
    m.sh(f"mkdir -p {REMOTE_DIR} {Path(REMOTE_START).parent.as_posix()}")
    m.sh("for p in $(ps | grep '[a]rcsnd' | awk '{print $1}'); do kill $p; done; sleep 1; true", check=False)
    put(m, binary, f"{REMOTE_DIR}/arcsnd")
    m.sh(f"chmod +x {REMOTE_DIR}/arcsnd")
    put(m, start, REMOTE_START)
    m.sh(f"chmod +x {REMOTE_START}")
    for s in SETS:
        h = OBJ / f"_handler_{s}.sh"
        h.write_bytes(HANDLER.format(dir=REMOTE_DIR).encode())
        m.sh(f"mkdir -p /media/fat/games/{s}")
        put(m, h, f"/media/fat/games/{s}/_handler.sh")
        m.sh(f"chmod +x /media/fat/games/{s}/_handler.sh")
    print(f"-> {REMOTE_DIR}/arcsnd, {REMOTE_START}, handlers for {', '.join(SETS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
