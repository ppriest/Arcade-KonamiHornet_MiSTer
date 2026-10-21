#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write releases/<description>.mra for each set in SETS and check its image.

    python scripts/gen_mra.py [set ...]

The index-0 image is KonamiHornet.sv's download layout: program ROM (4 MB), data ROM (8 MB),
CG ROM (16 MB), M48T58 (8 KB), then the sound board's 68000 program (512 KB) and samples as
stored, which the HPS's sound server (sw/arcsnd) reads from DDR3 after the fast load. The script
builds that image from the .mra with scripts/mra.py (mra-tools-c's semantics) and compares it byte
for byte with scripts/rom_images.py's images and the set's files; it writes nothing if they
differ. <mameversion> comes from MAME_EXE.
"""
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402
import mra  # noqa: E402

MB = 1024 * 1024
# prg: ROM_LOAD16_WORD_SWAP, loaded twice; data and cg: ROM_LOAD32_WORD_SWAP pairs, zeros to the
# data region's end (8 MB)
SETS = {
    "gradius4": dict(
        desc="Gradius IV: Fukkatsu (ver JAC)", file="Gradius IV Fukkatsu (ver JAC)", category="Shooter",
        prg="837c01.27p", data=("837a04.16t", "837a05.14t"),
        cg=(("837a13.24u", "837a14.32u"), ("837a15.24v", "837a16.32v")), nv="m48t58y-70pc1_jac",
        snd_prg="837a08.7s", snd_smp=("837a09.16p", "837a10.14p"),
        buttons="Shot,Missile,Power Up", dip1="", note=""),
    "nbapbp": dict(
        desc="NBA Play By Play (ver UAB)", file="NBA Play By Play (ver UAB)", category="Sports",
        prg="778b01.27p", data=("778a04.16t", "778a05.14t"),
        cg=(("778a13.24u", "778a14.32u"), ("778a15.24v", "778a16.32v")), nv="m48t58y-70pc1",
        snd_prg="778a08.7s", snd_smp=("778a09.16p", "778a10.14p", "778a11.12p", "778a12.9p"),
        buttons="Shoot,Pass,Turbo",
        dip1='\n        <dip name="Cabinet Type" bits="1" ids="4 Player,2 Player"/>',
        note=("\n    <!-- Untested on the core: the security EEPROM (X76F041) and the JVS I/O board are not\n"
              "         emulated; MAME says the game is regionless and bugged without the first -->")),
}


def crc(z, name):
    return f"{z.getinfo(name).CRC:08x}"


def write(setname, s, romdir, mamever):
    zpath = romdir / f"{setname}.zip"
    z = zipfile.ZipFile(zpath)

    def part(name, m=None):
        a = f' map="{m}"' if m else ""
        return f'<part name="{name}" crc="{crc(z, name)}"{a}/>'

    def pair(hi, lo):
        return ("        <interleave output=\"32\">\n"
                f"            {part(hi, '0012')}\n            {part(lo, '1200')}\n"
                "        </interleave>\n")

    prg = ("        <interleave output=\"16\">\n"
           f"            {part(s['prg'], '12')}\n        </interleave>\n")
    data_pad = 8 * MB - 2 * z.getinfo(s["data"][0]).file_size
    pad = f'        <part repeat="{data_pad:#x}">00</part>\n' if data_pad else ""
    smp = "".join(f"        {part(f)}\n" for f in s["snd_smp"])
    smp_mb = sum(z.getinfo(f).file_size for f in s["snd_smp"]) // MB
    text = f"""<misterromdescription>
    <name>{s['desc']}</name>
    <setname>{setname}</setname>
    <rbf>KonamiHornet</rbf>
    <mameversion>{mamever}</mameversion>
    <year>1998</year>
    <manufacturer>Konami</manufacturer>
    <category>{s['category']}</category>
    <rotation>horizontal</rotation>{s['note']}

    <!-- KonamiHornet.sv's download: program ROM 4 MB (the 2 MB ROM twice, as MAME's region),
         data ROM 8 MB, CG ROM 16 MB, M48T58 8 KB; then the sound board's 68000 program (512 KB)
         and samples ({smp_mb} MB) as stored, which the HPS's sound server reads from DDR3 (the
         fast load); written and checked by scripts/gen_mra.py -->
    <rom index="0" zip="{setname}.zip" md5="none" address="0x30000000">
        <!-- program ROM: ROM_LOAD16_WORD_SWAP, reloaded -->
{prg}{prg}        <!-- data ROM: ROM_LOAD32_WORD_SWAP, the first in bytes 0-1, the second in bytes 2-3 -->
{pair(*s['data'])}{pad}        <!-- CG ROM: ROM_LOAD32_WORD_SWAP pairs, the second at 8 MB -->
{''.join(pair(h, l) for h, l in s['cg'])}        <!-- M48T58: the set's NVRAM image -->
        {part(s['nv'])}
        <!-- the sound board (sw/arcsnd): at 0x1C02000 and 0x1C82000, hornet_sndbridge's PROG and SAMPLES -->
        {part(s['snd_prg'])}
{smp}    </rom>
    <!-- the M48T58 saved and restored (KonamiHornet.sv, ioctl index 4) -->
    <nvram index="4" size="8192"/>

    <switches default="7B">
        <dip name="Skip Post" bits="7" ids="On,Off"/>
        <dip name="Screen Flip (H)" bits="6" ids="On,Off"/>
        <dip name="Screen Flip (V)" bits="5" ids="On,Off"/>
        <dip name="Harness" bits="2" ids="JAMMA,JVS"/>{s['dip1']}
        <dip name="Monitor Type" bits="0" ids="15KHz,24KHz"/>
    </switches>

    <buttons names="{s['buttons']},Start,Coin,Service,Test" default="A,B,X,Start,Select,R,L"/>
</misterromdescription>
"""
    out = REPO / "releases" / f"{s['file']}.mra"
    out.parent.mkdir(exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(text)

    # the reference: rom_images.py's region images and the set's files
    subprocess.run([sys.executable, str(REPO / "scripts" / "rom_images.py"), setname], check=True,
                   capture_output=True)
    rd = REPO / "debug" / f"{setname}-roms"
    ref = ((rd / "prgrom.bin").read_bytes() + (rd / "datarom.bin").read_bytes() +
           (rd / "cgrom.bin").read_bytes() + z.read(s["nv"]) + z.read(s["snd_prg"]) +
           b"".join(z.read(f) for f in s["snd_smp"]))
    img = mra.build_image(str(tmp), str(zpath))
    if img != ref:
        n = next((i for i in range(min(len(img), len(ref))) if img[i] != ref[i]), min(len(img), len(ref)))
        tmp.unlink()
        sys.exit(f"{setname}: image differs from the reference at {n:#x} (sizes {len(img):#x}, {len(ref):#x})")
    tmp.replace(out)
    print(f"{out}: image {len(img):#x} bytes, identical to rom_images.py's")


def main():
    env = load_env()
    romdir = Path(env["MAME_ROMPATH"].split(";")[0])
    exe = Path(env["MAME_DIR"]) / env.get("MAME_EXE", "mame.exe")
    ver = subprocess.run([str(exe), "-version"], capture_output=True, text=True).stdout.split()[0]
    mamever = "0" + ver.split(".")[1]
    for name in sys.argv[1:] or list(SETS):
        write(name, SETS[name], romdir, mamever)


if __name__ == "__main__":
    main()
