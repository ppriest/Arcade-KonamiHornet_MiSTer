#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write releases/<description>.mra for each set in SETS and check its image.

    python scripts/gen_mra.py [set ...]

The index-0 image is KonamiHornet.sv's download layout: program ROM (4 MB), data ROM (8 MB),
CG ROM (16 MB), M48T58 (8 KB), then the sound board's 68000 program (512 KB) and samples as
stored, which the HPS's sound server (MiSTer_ArcadeSoundServer) reads from DDR3 after the fast load. The script
builds that image from the .mra with scripts/mra.py (mra-tools-c's semantics) and compares it byte
for byte with scripts/rom_images.py's images and the set's files; it writes nothing if they
differ. <mameversion> comes from MAME_EXE. A clone (SETS "parent") is its parent's entry with its
own files and names; its .mra goes to releases/_alternatives/_<game>/ and names its zip and then
the parent's (zip="clone.zip|parent.zip"), whose merged form keeps the clone's files under "<clone>/".
"""
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402
import mra  # noqa: E402
import rom_images  # noqa: E402

MB = 1024 * 1024
# prg: ROM_LOAD16_WORD_SWAP, loaded twice; data and cg: ROM_LOAD32_WORD_SWAP pairs, zeros to the
# data region's end (8 MB)
SETS = {
    "gradius4": dict(
        desc="Gradius IV: Fukkatsu (ver JAC)", file="Gradius IV Fukkatsu (ver JAC)", category="Shooter",
        prg="837c01.27p", data=("837a04.16t", "837a05.14t"),
        cg=(("837a13.24u", "837a14.32u"), ("837a15.24v", "837a16.32v")), nv="m48t58y-70pc1_jac",
        snd_prg="837a08.7s", snd_smp=("837a09.16p", "837a10.14p"),
        buttons="Power Up,Shot,Missile", dip1="", note=""),
    "nbapbp": dict(
        desc="NBA Play By Play (ver UAB)", file="NBA Play By Play (ver UAB)", category="Sports",
        prg="778b01.27p", data=("778a04.16t", "778a05.14t"),
        cg=(("778a13.24u", "778a14.32u"), ("778a15.24v", "778a16.32v")), nv="m48t58y-70pc1",
        snd_prg="778a08.7s", snd_smp=("778a09.16p", "778a10.14p", "778a11.12p", "778a12.9p"),
        buttons="Shoot,Pass,Turbo",
        dip1='\n        <dip name="Cabinet Type" bits="1" ids="4 Player,2 Player"/>',
        note=("\n    <!-- Untested on the core: the security EEPROM (X76F041) and the JVS I/O board are not\n"
              "         emulated; MAME says the game is regionless and bugged without the first -->")),
    # Gradius IV's clones (MAME 0.289 -listclones gradius4): program ROM, NVRAM image, names
    "gradius4a": dict(parent="gradius4", desc="Gradius IV (ver AAC)", file="Gradius IV (ver AAC)",
                      prg="837c01.27p", nv="m48t58y-70pc1_aac"),
    "gradius4u": dict(parent="gradius4", desc="Gradius IV (ver UAC)", file="Gradius IV (ver UAC)",
                      prg="837c01.27p", nv="m48t58y-70pc1_uac"),
    "gradius4aa": dict(parent="gradius4", desc="Gradius IV (ver AAA)", file="Gradius IV (ver AAA)",
                       prg="837a01.27p", nv="m48t58y-70pc1_aaa"),
    "gradius4ja": dict(parent="gradius4", desc="Gradius IV: Fukkatsu (ver JAA)",
                       file="Gradius IV Fukkatsu (ver JAA)", prg="837a01.27p", nv="m48t58y-70pc1_jaa"),
    "gradius4ua": dict(parent="gradius4", desc="Gradius IV (ver UAA)", file="Gradius IV (ver UAA)",
                       prg="837a01.27p", nv="m48t58y-70pc1_uaa"),
}
ALT_DIR = {"gradius4": "_Gradius IV"}       # a parent's clones' folder under releases/_alternatives


CHEAT_MAX = 16                          # KonamiHornet.sv's store: 16 codes
SEVEN_ZIP = Path("C:/Program Files/7-Zip/7z.exe")


def cheat_codes(script):
    """A MAME cheat script's actions as codes (flags, address, value), or None if one is not a byte
    write the core can apply every frame: pb@a=v, or pb@a=v|(pb@a BAND ~v) (an OR)."""
    codes = []
    for act in script.findall("action"):
        s = re.sub(r"\s+", "", act.text or "")
        m = re.fullmatch(r"maincpu\.pb@([0-9A-Fa-f]+)=([0-9A-Fa-f]+)", s)
        if m:
            codes.append((0, int(m[1], 16), int(m[2], 16)))
            continue
        m = re.fullmatch(r"maincpu\.pb@([0-9A-Fa-f]+)=([0-9A-Fa-f]+)\|\(maincpu\.pb@\1BAND~\2\)", s)
        if m:
            codes.append((1, int(m[1], 16), int(m[2], 16)))
            continue
        return None
    return codes


def mame_cheats(setname, mame_dir):
    """[(name, codes)] from MAME's cheat.7z for the set; the run scripts (an on-only script is applied
    every frame too), a parameter's values as one cheat each. Others are left out."""
    archive = Path(mame_dir) / "cheat.7z"
    if not archive.exists() or not SEVEN_ZIP.exists():
        return []
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([str(SEVEN_ZIP), "e", "-y", f"-o{d}", str(archive), f"{setname}.xml"],
                       capture_output=True, check=False)
        f = Path(d) / f"{setname}.xml"
        if not f.exists():
            return []
        root = ET.parse(f).getroot()
    out = []
    for ch in root.findall("cheat"):
        desc = (ch.get("desc") or "").strip()
        if not desc:
            continue
        scripts = {s.get("state", "run"): s for s in ch.findall("script")}
        script = scripts.get("run", scripts.get("on"))
        if script is None:
            continue
        par = ch.find("parameter")
        if par is None:
            codes = cheat_codes(script)
            if codes:
                out.append((desc, codes))
            continue
        items = [(int(i.get("value"), 0), i.text.strip()) for i in par.findall("item")]
        if not items and par.get("min") is not None:
            lo, hi, st = (int(par.get(k), 0) for k in ("min", "max", "step"))
            items = [(v, str(v)) for v in range(lo, hi + 1, st)]
        for v, label in items:
            fake = ET.fromstring("<script>" + "".join(
                f"<action>{re.sub(r'[(]?param[)]?', f'{v:02X}', a.text)}</action>"
                for a in script.findall("action")) + "</script>")
            codes = cheat_codes(fake)
            if codes:
                out.append((f"{desc}: {label}", codes))
    return out


def cheats_block(cheats):
    if not cheats:
        return ""
    lines = [f'    <cheats size="16" max="{CHEAT_MAX}">']
    for name, codes in cheats:
        hexs = "".join(f.to_bytes(4, "little").hex() + a.to_bytes(4, "little").hex() + "00000000" +
                       v.to_bytes(4, "little").hex() for f, a, v in codes)
        lines.append(f'        <cheat name="{name}">{hexs}</cheat>')
    lines.append("    </cheats>")
    return "\n" + "\n".join(lines) + "\n"


def write(setname, s, romdir, mamever, mame_dir):
    parent = s.get("parent")
    if parent:
        s = {**SETS[parent], **s}
    z = rom_images.SetZips(romdir, setname)
    zips = f"{setname}.zip|{parent}.zip" if parent else f"{setname}.zip"

    def part(name, m=None):
        a = f' map="{m}"' if m else ""
        return f'<part name="{name}" crc="{z.crc(name)}"{a}/>'

    def pair(hi, lo):
        return ("        <interleave output=\"32\">\n"
                f"            {part(hi, '0012')}\n            {part(lo, '1200')}\n"
                "        </interleave>\n")

    prg = ("        <interleave output=\"16\">\n"
           f"            {part(s['prg'], '12')}\n        </interleave>\n")
    data_pad = 8 * MB - 2 * z.size(s["data"][0])
    pad = f'        <part repeat="{data_pad:#x}">00</part>\n' if data_pad else ""
    smp = "".join(f"        {part(f)}\n" for f in s["snd_smp"])
    smp_mb = sum(z.size(f) for f in s["snd_smp"]) // MB
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
    <rom index="0" zip="{zips}" md5="none" address="0x30000000">
        <!-- program ROM: ROM_LOAD16_WORD_SWAP, reloaded -->
{prg}{prg}        <!-- data ROM: ROM_LOAD32_WORD_SWAP, the first in bytes 0-1, the second in bytes 2-3 -->
{pair(*s['data'])}{pad}        <!-- CG ROM: ROM_LOAD32_WORD_SWAP pairs, the second at 8 MB -->
{''.join(pair(h, l) for h, l in s['cg'])}        <!-- M48T58: the set's NVRAM image -->
        {part(s['nv'])}
        <!-- the sound board (MiSTer_ArcadeSoundServer): at 0x1C02000 and 0x1C82000, hornet_sndbridge's PROG and SAMPLES -->
        {part(s['snd_prg'])}
{smp}    </rom>
    <!-- the M48T58 saved and restored (KonamiHornet.sv, ioctl index 4) -->
    <nvram index="4" size="8192"/>
{cheats_block(mame_cheats(setname, mame_dir))}
    <!-- MAME's defaults (0x7B) but Monitor Type 15KHz -->
    <switches default="7A">
        <dip name="Skip Post" bits="7" ids="On,Off"/>
        <dip name="Screen Flip (H)" bits="6" ids="On,Off"/>
        <dip name="Screen Flip (V)" bits="5" ids="On,Off"/>
        <dip name="Harness" bits="2" ids="JAMMA,JVS"/>{s['dip1']}
        <dip name="Monitor Type" bits="0" ids="15KHz,24KHz"/>
    </switches>

    <buttons names="{s['buttons']},Start,Coin,Service,Test" default="A,B,X,Start,Select,R,L"/>
</misterromdescription>
"""
    out = REPO / "releases" / (Path("_alternatives") / ALT_DIR[parent] if parent else Path()) / f"{s['file']}.mra"
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(text)

    # the reference: rom_images.py's region images and the set's files
    subprocess.run([sys.executable, str(REPO / "scripts" / "rom_images.py"), setname], check=True,
                   capture_output=True)
    rd = REPO / "debug" / f"{setname}-roms"
    ref = ((rd / "prgrom.bin").read_bytes() + (rd / "datarom.bin").read_bytes() +
           (rd / "cgrom.bin").read_bytes() + z.read(s["nv"]) + z.read(s["snd_prg"]) +
           b"".join(z.read(f) for f in s["snd_smp"]))
    img = mra.build_image(str(tmp), [str(p) for p in z.paths])
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
        write(name, SETS[name], romdir, mamever, env["MAME_DIR"])


if __name__ == "__main__":
    main()
