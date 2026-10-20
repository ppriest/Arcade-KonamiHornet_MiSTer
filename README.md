# Konami Hornet core for MiSTer

A MiSTer FPGA core for Konami's Hornet arcade hardware (MAME's `konami/hornet.cpp`), built with
Quartus Prime 17.0.2 Lite for the DE10-nano.

**Status: in development. Gradius IV boots to attract and into a game on a DE10-nano, 2D and 3D
drawn; not yet played through, and no sound.**

## Contents

- [History](#history)
- [Games](#games)
  - [Supported](#supported)
  - [Not yet](#not-yet)
  - [Out of scope for now](#out-of-scope-for-now)
- [Hardware](#hardware)
  - [Video timing](#video-timing)
- [Screenshots](#screenshots)
- [Installation](#installation)
- [Controls](#controls)
- [Status](#status)
  - [Features](#features)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## History

No release yet.

- `a034e0d`: attract at 97% of full frame rate on the DE10-nano (9 frames a second before): the
  Voodoo's DDR3 masters move 64 bits a clock, and a texture miss fills up to eight tiles in one
  burst. In-game sections still slow down.
- `4376611`: the title screen matches MAME on the DE10-nano (`debug/hw/portc_boot.png`). Port C
  answers a miss from its fill's first half, and the K037122 builder works up to three lines ahead:
  no unbuilt lines (probe H).
- `67a4bb6`: textures right. Port B addressed the CG ROM 8 MB from where the download puts it.
- `cf13d8d`: the Voodoo's picture shows: its CLUT starts as MAME's grey ramp.
- `f94e1a3`, `a804e5c`: the M48T58 is saved to the `.nvm` file; Test switch; the M48T58's clock.
- `abaffc9`: the PPC's character RAM writes reach memory (they were dropped by a 23-bit address
  in a 24-bit decode), so the start-up text can draw.
- `6a3ce09`: first runs on a DE10-nano. Gradius IV boots to its start-up messages, placed where
  MAME places them, with unreadable glyphs.

## Games

The core targets the Hornet main board with one 3D (CG) board: a PowerPC 403GA, an ADSP-21062
SHARC, a 3dfx Voodoo 1 and a K037122 tilemap. Gradius IV is the first target; NBA Play By Play
is the same board plus JVS. The ROMs take 28 MB of SDRAM; the Voodoo's frame buffer and texture
memory are in DDR3.

### Supported

Sets with an `.mra` in `releases/`. None is verified playable yet.

| Name | Year | Manufacturer | Controls | Notes |
|-|-|-|-|-|
| Gradius IV: Fukkatsu (ver JAC) | 1998 | Konami | 8-way joystick, three buttons, two players | attract and a game start; no sound |

### Not yet

| Name | Why |
|-|-|
| Gradius IV clones (u, a, ua, aa) | no `.mra` yet; same board as the parent |
| NBA Play By Play and its clones | needs the JVS host on the PPC's serial port |

### Out of scope for now

| MAME description | Why |
|-|-|
| Teraburst and clones | GN680 board; `MACHINE_NOT_WORKING` in MAME |
| Thrill Drive (Hornet LAN sets) | LAN board; `MACHINE_NOT_WORKING` in MAME |
| Silent Scope, Silent Scope 2 and Voodoo 2 variants | two 3D boards or a Voodoo 2; `MACHINE_NOT_WORKING` in MAME |

## Hardware

| Chip | Function | Status |
|-|-|-|
| IBM PPC403GA @ 32 MHz | main CPU | written here from MAME's PowerPC model; 1,000,000 instructions from reset and 2.7 M in two game windows match MAME's trace in PC and 37 registers. Runs at 64 MHz with a 1 KB instruction cache |
| ADSP-21062 SHARC @ 36 MHz | geometry DSP | written here from MAME's model; 2.3 M instructions in two game windows match MAME's trace in PC and 56 registers, floating point bit-exact on 9.2 M vectors. Runs on its own 48 MHz clock |
| 3dfx Voodoo 1 | rasteriser, 2 MB frame buffer, 4 MB texture memory | written here (`vraster`) for the subset Gradius IV uses, from MAME's model; frame and texture memory in DDR3 |
| K037122 | tilemap overlay and the 8192-colour palette | written here from MAME's model; the overlay's rotate and zoom are built, Gradius IV does not use them |
| K033906 | the Voodoo's PCI configuration | written here from MAME's model |
| M48T58 | 8 KB NVRAM and clock | written here; the clock from MAME's timekeeper, set from the MiSTer's time; saved to the `.nvm` file |
| konppc glue, sysreg | shared RAM, comm registers, interrupts, inputs | written here from `hornet.cpp` and `konppc.cpp` |
| MC68000, K056800, RF5C400 | sound | not built; a stand-in answers the PPC's sound handshake |
| X76F041 | security EEPROM | not built |

### Video timing

16 MHz dot clock (64 MHz / 4), 640 dots per line (25 kHz) and 428 lines per frame (58.41 Hz). The
visible area is 512×384. MAME's `set_raw()` declares 644 dots per line (24.84 kHz, 58.05 Hz) and
doubts its own input clock; at run time MAME picks the line rate from the Voodoo's registers and
lands on 25 kHz for Gradius IV. The sync pulses are placed by the core, not from the Voodoo's
registers (`docs/HACKS.md`). There is no PCB measurement.

## Screenshots

### Gradius IV: Fukkatsu

![gradius4 title](docs/screenshots/gradius4/title.png)

## Installation

A 128 MB SDRAM module is required (the core uses 28 MB of it).

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`, renamed to drop the
  `Arcade-` prefix (`Arcade-KonamiHornet_YYYYMMDD.rbf` becomes `KonamiHornet_YYYYMMDD.rbf`). MiSTer
  launches the highest-sorting match for `<rbf>KonamiHornet</rbf>`, and a `KonamiHornet_*.rbf`
  sorts above every `Arcade-KonamiHornet_*.rbf`
* Take the `*.mra` files from `releases/` and put them in `_Arcade`
* Put the MAME `gradius4` set in `games/mame`

To run a development build instead: `python scripts/build_staged.py`, then `python scripts/deploy.py`
with a `mister.env` (see `scripts/deploy.py`).

## Controls

| Input | Gradius IV | Default pad button |
|-|-|-|
| Joystick | move | d-pad |
| Button 1 | Shot | A |
| Button 2 | Missile | B |
| Button 3 | Power Up | X |
| Start | Start | Start |
| Coin | Coin | Select |
| Service | Service (player 2's: Service 2) | R |
| Test | the test switch | L |
| Pause | suspends the PPC | Y |

Both players have the same layout on the first and second controllers.

## Status

Known issues:

- **Not yet played through on hardware; gameplay is unverified beyond the first stage's start.**
- **No sound** (the 68000, K056800 and RF5C400 are not built).
- The ROMs load over the slow path; fast loading through DDR3 is not built.
- Flip screen is not built, and the security EEPROM is absent.
- **The first boot stops at "RTC CHECKSUM ERROR! ... PRESS TEST SWITCH TO CONTINUE"**, as MAME's does with the set's NVRAM image: press Test (L). The settings are then saved to the `.nvm` file.

`docs/MAME_KLUDGES.md` lists what is taken from MAME as behaviour and what is known not to be
right. `docs/HACKS.md` lists this core's own approximations. `docs/ROADMAP.md` is the plan and its
progress; `docs/LESSONS_LEARNED.md` is what it cost.

### Features

* DIP switches from the `.mra` (`DIP;` in the OSD): done
* Inputs: two players, three buttons, service, test; done
* CRT Adjust (H-Position, V-Shift, H-Size, V-Size): not yet
* HDMI scaling (integer scale, crop, crop offset): not yet
* HDMI rotation (orientation): n/a (horizontal monitor)
* Flip screen, HDMI and analog, from the OSD or the DIP (fake DIP where the game has none): not yet
* HDMI-only options hidden under direct video: not yet
* Peripheral menus shown only for games that use them: n/a (no peripherals)
* Rotary joysticks: n/a
* Light guns: n/a
* Audio mix (Mono, None, 25%, 50%): not yet (no sound)
* Hiscore saving (`hiscore.v`, with autosave): not yet
* NVRAM / EEPROM saved to the `.nvm` file: the M48T58, a second after the game's last write (not yet checked on hardware); no EEPROM
* Fast ROM loading via DDR: not yet
* Pause (with CPU suspended): done (the PPC stops; the SHARC, Voodoo and picture keep running)
* Sound: not yet
* Savestates (optional): not yet
* Cheats (optional): not yet

### Todo

- [x] Boot to attract on hardware
- [ ] Play through on hardware
- [ ] Fast ROM loading through DDR3
- [ ] Flip screen
- [ ] Security EEPROM (X76F041) and JVS
- [ ] Sound: fx68k, K056800, RF5C400

### Resource usage

The release revision `KonamiHornet` at `c9ec65b` (default seed) on the DE10-nano's Cyclone V
5CSEBA6, speed grade 7; setup and hold met on every clock (worst setup +0.168 ns, the HDMI scaler):

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 39,214 | 41,910 |
| Block memory bits | 4,370,788 | 5,662,720 |
| RAM blocks | 543 | 553 |
| DSP blocks | 93 | 112 |
| PLLs | 3 | 6 |

Logic is the resource to watch: the SHARC is the largest block, and adding sound has to fit in
what is left.

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant, which wrote the RTL,
the testbenches, the tooling and these documents under the author's direction. The author tests
it on hardware.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted
where they matter.

* **PPC403GA:** 1,000,000 instructions from reset, 743,505 at frame 3000 (attract) and 2,000,000
  at frame 7500 (stage 1) against MAME's trace; PC and 37 registers identical at every one.
* **SHARC:** 300,000 instructions at frame 3000 and 2,000,000 at frame 7500 against MAME's trace;
  PC and 56 registers identical. Floating point against MAME's host-float code: 9,200,000
  vectors, 0 mismatches.
* **Voodoo (`vraster`):** frames 2150, 7500 and 3000 replayed from MAME's state: 150, 5 and 0 of
  196,608 pixels differ (fixed-point perspective divide, `docs/HACKS.md`).
* **Whole board in Verilator** from MAME snapshots: at frame 7500 the screen matches MAME's in
  7501 (0 of 196,608 pixels differ) and the buffer swaps keep step; from boot snapshots the
  pictures match MAME's through frames 159, 225 and 646, and the boot reaches attract ("CREDITS 00"
  at frame 647, MAME 683; the difference is not explained). Character
  RAM after the start-up writes (frames 140-150): 0 of 524,288 words differ.
* **Memory paths:** the SDRAM ports and the DDR3 arbiter in their own benches against chip models
  (`sim/sdram_tb`, `sim/ddr3_tb`).
* **Hardware against MAME:** the Voodoo's texture memory read back from the DE10-nano's DDR3
  (`/dev/mem`) compared word for word with MAME's; the title screen against MAME's frame 2400.
* **`.mra`:** its ROM image byte-identical to the regions built from MAME's `ROM_START`.

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for the
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework, and Sorgelig for
  the SDRAM controller this core's is extended from.
- The **MAMEdev team** — Ville Linde for `hornet.cpp`, `konppc.cpp` and the SHARC; Aaron Giles and
  R. Belmont for the PowerPC; Aaron Giles for the Voodoo; Fabio Priuli, Acho A. Tang and R. Belmont
  for the K037122 — for the driver and device emulations that are this core's specification.
- **fayalalebrun** for [SpinalVoodoo](https://github.com/fayalalebrun/SpinalVoodoo), the Voodoo
  this project ran in simulation before `vraster`; it is not in the bitstream.

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template, never edited |
| `rtl` | core source; vendored modules carry a `PROVENANCE.md` |
| `releases` | `.rbf` and `.mra` files |
| `docs` | roadmap, workflow, release process, kludges, hacks, lessons |
| `sim` | ModelSim and Verilator testbenches |
| `scripts` | build, deploy, capture and verification tooling |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL-3.0-or-later (see `LICENSE`). Imported components keep their own licences, and every modified
vendored file states the change in its header.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
