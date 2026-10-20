#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write releases/<description>.mra for gradius4 and check its image.

    python scripts/gen_mra.py

The index-0 image is KonamiHornet.sv's download layout: program ROM (4 MB), data ROM (8 MB),
CG ROM (16 MB), M48T58 (8 KB). The script builds that image from the .mra with scripts/mra.py
(mra-tools-c's semantics) and compares it byte for byte with scripts/rom_images.py's images and
the set's M48T58 file; it writes nothing if they differ. <mameversion> comes from MAME_EXE.
"""
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402
import mra  # noqa: E402

SET = "gradius4"
DESC = "Gradius IV: Fukkatsu (ver JAC)"
FILE = "Gradius IV Fukkatsu (ver JAC)"     # no colon in a file name
NV = "m48t58y-70pc1_jac"


def crc(z, name):
    return f"{z.getinfo(name).CRC:08x}"


def main():
    env = load_env()
    romdir = Path(env["MAME_ROMPATH"].split(";")[0])
    zpath = romdir / f"{SET}.zip"
    z = zipfile.ZipFile(zpath)
    exe = Path(env["MAME_DIR"]) / env.get("MAME_EXE", "mame.exe")
    ver = subprocess.run([str(exe), "-version"], capture_output=True, text=True).stdout.split()[0]
    mamever = "0" + ver.split(".")[1]

    def part(name, m=None):
        a = f' map="{m}"' if m else ""
        return f'<part name="{name}" crc="{crc(z, name)}"{a}/>'

    def pair(hi, lo):
        return ("        <interleave output=\"32\">\n"
                f"            {part(hi, '0012')}\n            {part(lo, '1200')}\n"
                "        </interleave>\n")

    prg = ("        <interleave output=\"16\">\n"
           f"            {part('837c01.27p', '12')}\n        </interleave>\n")
    text = f"""<misterromdescription>
    <name>{DESC}</name>
    <setname>{SET}</setname>
    <rbf>KonamiHornet</rbf>
    <mameversion>{mamever}</mameversion>
    <year>1998</year>
    <manufacturer>Konami</manufacturer>
    <category>Shooter</category>
    <rotation>horizontal</rotation>

    <!-- KonamiHornet.sv's download: program ROM 4 MB (the 2 MB ROM twice, as MAME's region),
         data ROM 8 MB, CG ROM 16 MB, M48T58 8 KB; written and checked by scripts/gen_mra.py -->
    <rom index="0" zip="{SET}.zip" md5="none">
        <!-- program ROM: ROM_LOAD16_WORD_SWAP, reloaded -->
{prg}{prg}        <!-- data ROM: ROM_LOAD32_WORD_SWAP, a04 in bytes 0-1, a05 in bytes 2-3 -->
{pair('837a04.16t', '837a05.14t')}        <part repeat="0x400000">00</part>
        <!-- CG ROM: ROM_LOAD32_WORD_SWAP pairs, the second at 8 MB -->
{pair('837a13.24u', '837a14.32u')}{pair('837a15.24v', '837a16.32v')}        <!-- M48T58: the set's NVRAM image -->
        {part(NV)}
    </rom>
    <!-- the M48T58 saved and restored (KonamiHornet.sv, ioctl index 4) -->
    <nvram index="4" size="8192"/>

    <switches default="7B">
        <dip name="Skip Post" bits="7" ids="On,Off"/>
        <dip name="Screen Flip (H)" bits="6" ids="On,Off"/>
        <dip name="Screen Flip (V)" bits="5" ids="On,Off"/>
        <dip name="Harness" bits="2" ids="JAMMA,JVS"/>
        <dip name="Monitor Type" bits="0" ids="15KHz,24KHz"/>
    </switches>

    <buttons names="Shot,Missile,Power Up,Start,Coin,Service,Test" default="A,B,X,Start,Select,R,L"/>
</misterromdescription>
"""
    out = REPO / "releases" / f"{FILE}.mra"
    out.parent.mkdir(exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(text)

    # the reference: rom_images.py's region images and the NVRAM file
    subprocess.run([sys.executable, str(REPO / "scripts" / "rom_images.py"), SET], check=True,
                   capture_output=True)
    rd = REPO / "debug" / f"{SET}-roms"
    ref = ((rd / "prgrom.bin").read_bytes() + (rd / "datarom.bin").read_bytes() +
           (rd / "cgrom.bin").read_bytes() + z.read(NV))
    img = mra.build_image(str(tmp), str(zpath))
    if img != ref:
        n = next((i for i in range(min(len(img), len(ref))) if img[i] != ref[i]), min(len(img), len(ref)))
        tmp.unlink()
        sys.exit(f"image differs from the reference at {n:#x} (sizes {len(img):#x}, {len(ref):#x})")
    tmp.replace(out)
    print(f"{out}: image {len(img):#x} bytes, identical to rom_images.py's")


if __name__ == "__main__":
    main()
