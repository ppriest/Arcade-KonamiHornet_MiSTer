# Konami Hornet: hardware notes

Source: MAME `src/mame/konami/hornet.cpp` and the devices it instantiates, checkout `E:/mame` at
`mame0289-661-ga2d0f76268e`. References are traced with vanilla MAME 0.289
(`C:/Emulation/Emulators/MAME`): the only full build on this machine (`E:/mame/mame.exe` is a
subtarget without Konami). `H:` is `hornet.cpp`.

## Sets

| Parent | Config | Clones | MAME status |
|---|---|---|---|
| gradius4 | `hornet_x76` | u, a, ja, ua, aa (H:3667-3672) | working, imperfect sound |
| nbapbp | `nbapbp` (x76 + Windy2 JVS) | a, j, ua, aa, ja, nbaatw, nbaatwa (H:3674-3681) | working |
| terabrst | `terabrst` (GN680) | 5 (H:3683-3695) | NOT_WORKING |
| thrilld (parent in nwk-tr.cpp) | `hornet_lan` | 8 (H:3708-3715) | NOT_WORKING |
| sscope, sscope2 and Voodoo 2 variants | two boards / Voodoo 2 | 42 (H:3718-3764) | NOT_WORKING |

First target: `gradius4`. `nbapbp` has the same board plus JVS; everything else is NOT_WORKING in
MAME or needs a second 3D board.

## Chips (gradius4)

| Part | Clock | Source | Role |
|---|---|---|---|
| IBM PPC403GA | 64 MHz / 2 | H:1394 | main CPU; no FPU, no MMU (ppccom.cpp:327-334) |
| MC68000 | 64 MHz / 4 | H:1403 | sound CPU |
| ADSP-21062 SHARC | 36 MHz | H:1407 | geometry; boots from shared RAM (`BOOT_MODE_EPROM`) |
| 3dfx Voodoo 1 | 50 MHz | H:1418-1421 | 2 MB frame buffer, one TMU with 4 MB |
| K033906 | - | H:1427 | PCI config space for the Voodoo only (k033906.cpp:53-119) |
| K037122 | - | H:1435 | 2D ROZ tilemap overlay, 8bpp, 8192-colour RGB565 palette |
| K056800 | 16.9344 MHz | H:1438 | host/sound mailbox; IRQ2 to the 68000 |
| RF5C400 | 16.9344 MHz | H:1443 | 32-channel PCM, 8 MB samples |
| M48T58 | - | H:1447 | 8 KB NVRAM + RTC |
| X76F041 | - | H:1468 | security EEPROM on sysreg 4 bits 0-2 (H:742-758) |

Screen: `set_raw(16 MHz, 644, 41, 553, 428, 27, 411)`, 512x384, 24.84 kHz, 58.05 Hz (H:1432). The
comment on that line doubts the input clock.

## PPC403 memory map (H:947-963)

| Address | Contents |
|---|---|
| `00000000-003FFFFF` | work RAM, 4 MB (DRC fastram, H:1326) |
| `74000000-740000FF` | K037122 registers |
| `74020000-7403FFFF` | K037122 tile + palette RAM, 128 KB |
| `74040000-7407FFFF` | K037122 char RAM window, bank from reg `0x30` bits 0-2 (2 MB total) |
| `78000000-7800FFFF` | SHARC shared RAM, the PPC's 64 KB bank |
| `780C0000-780C0003` | SHARC comm register (konppc.cpp:153-184) |
| `7D000000` / `7D010000` | sysreg read / write, 8-bit |
| `7D020000-7D021FFF` | M48T58 |
| `7D030000-7D03000F` | K056800 host side |
| `7E000000-7E7FFFFF` | data ROM window; gradius4 fills 4 MB |
| `7F000000-7F3FFFFF`, `7FC00000-7FFFFFFF` | program ROM, 2 MB mirrored; reset vector `FFFFFFFC` |

Interrupts: IRQ0 = 3D board vblank (Voodoo vblank callback, H:1424), IRQ1 = second board, IRQ2 =
LAN, NMI = serial (H:1311-1316). IRQ0 cleared by sysreg 7 bit 6 (H:813-817).

## SHARC data map (H:1057-1066, 32-bit words)

| Address | Contents |
|---|---|
| `0400000-041FFFF` | shared RAM, 16-bit halves; two 64 KB banks, PPC sees N, SHARC N^1 (konppc.cpp:291-313) |
| `0500000-05FFFFF` | 1 M-word RAM, reads masked to 16 bits |
| `1400000-14FFFFF` | 1 M-word RAM |
| `2400000-27FFFFF` | Voodoo registers, LFB, texture writes |
| `3400000-34000FF` | comm registers |
| `3500000-35000FF` | K033906 |
| `3600000-37FFFFF` | CG ROM, 2 x 8 MB banks, bank from SHARC comm offset 1 bit 3 (konppc.cpp:268-276) |

The SHARC boots by DMA channel 6 copying 0x600 words from shared RAM to 0x20000 (sharc.cpp:932-967):
the PPC writes the kernel, then releases reset through comm bit 28.

## 68000 map (H:1001-1011)

ROM `000000-07FFFF`, RAM `100000-10FFFF`, RF5C400 `200000`, K056800 `300000` (odd bytes), timer
enable/ack `500000`/`600000`. IRQ1 periodic at 16.9344 MHz / 384 / 128 = 344.5 Hz.

## ROMs (`mame -listxml gradius4`)

| Region | Bytes | Consumer |
|---|---|---|
| program | 2 MB (837c01.27p) | PPC |
| data | 4 MB (837a04, 837a05) | PPC |
| CG | 16 MB (837a13-16) | SHARC, direct reads |
| sound program | 512 KB (837a08) | 68000 |
| samples | 8 MB (837a09, 837a10) | RF5C400 |
| NVRAM, X76F041 | 8 KB, 548 B | both BAD_DUMP, hand-built (H:2896, 2900) |

Total 30.5 MB of ROM. RAM besides: PPC 4 MB, SHARC 2 x 4 MB external (only as much as used needs
storing), Voodoo 6 MB, K037122 2 MB char + 128 KB, shared 128 KB.

## Measured workload (MAME 0.289, `scripts/hornet_load.py`)

gradius4 from an NVRAM set up once through the RTC/clock screens (`debug/nvram/`, not committed).
Attract = frames 700-4299; play = frames 4440-8400, coin at 4400, stage 1 with one death. Per frame,
min / median / p95 / max. MAME's CPU timing has no cache or bus-wait model: busy figures are lower
bounds.

| | attract | play |
|---|---|---|
| triangles | 0 / 30 / 1319 / 1763 | 0 / 540 / 1654 / 2031 |
| triangle pixels (`fbiPixelsIn`) | 0 / 205,678 / 340,930 / 589,824 | 0 / 10,738 / 57,210 / 71,151 |
| pixels out incl. fastfill (`fbiPixelsOut`) | 0 / 408,466 / 580,680 / 786,432 | 0 / 201,765 / 239,702 / 589,824 |
| fastfill clears | 0 / 1 / 2 / 2 | 0 / 1 / 1 / 2 |
| texture upload bytes | 0 / 0 / 0 / 75,776 | 0 / 0 / 0 / 84,252 |
| PPC to shared RAM bytes | 0 / 564 / 15,098 / 18,700 | 2 / 9,318 / 17,648 / 193,040 |
| PPC busy % | 0 / 3.5 / 38 / 72 | 0 / 13 / 33 / 100 |
| SHARC busy % | 0 / 2.9 / 62 / 93 | 0 / 5.6 / 72 / 86 |

- One buffer swap per vblank: the game runs at 58.05 Hz.
- Every triangle pixel is textured, perspective-correct and bilinear from one TMU; depth is a
  W-buffer; alpha blend src-alpha on 94% (attract) / 98% (play) of the area; alpha test and chroma
  key on. No mipmapping (`tLOD` min = max), no fog, no LFB writes, no trilinear.
- Texture formats by area: RGB565, ARGB4444, a trace of RGB332.
- Textures travel CG ROM -> SHARC -> TMU writes, in bursts at scene loads.
- The SHARC is never reset during play and its code is identical in attract and play.
- PPC idle loop: 0x802024D4-0x8020253F, waiting for the vblank counter.

## SHARC usage (MAME 0.289 -nodrc, `scripts/sharc_profile.py`)

Windows: attract 2800-3400, demo 1900-2300, play 7000-7600; debugger traces of about a million
instructions at frames 2150 (demo) and 7500 (play).

- **Internal data RAM: block 1 only, 6,082 words** touched over all windows, all below word
  0x26E0 (runs 0000-010B, 0200-02EF, 0338-1063, 1BC8-1C6F, 1DF0-26DF). Block 0 holds code and
  no data.
- **Code: executed PCs 0x2001C-0x245C0**, about 0x45A5 48-bit words at most; the program is
  unchanged over each trace.
- External: RAM at 0x1400000 up to 29,474 distinct words in attract; RAM at 0x500000 not seen.
- No circular buffers (L registers zero), no PM-bus data accesses, loop stack depth <= 1, PC
  stack depth <= 4 in samples.
- MODE1 toggles 0x480 (alternate register sets) about 5,000 times per million instructions;
  MODE2 0x00080013; IMASK 0x183. Interrupt used: IRQ1 (vector 0x2001C), once per frame.
- DMA: channel 6 (up to 96 starts per frame) and channel 7 chained (up to 1,763 starts per
  frame); chained TCBs 3.47 M over the run.
- Instruction mix in play: compute + DM load 29%, compute + DM store 11%, compute + ureg move
  10%, compute 7%, sysreg bit op 7%, relative jump 7%, imm shift + move 6%. Compute units: float
  multifunction (FMUL with FADD/FSUB/FMAX/FMIN/FLOAT/FIX) 17%, FMUL 16%, float ALU 14%, fixed
  ALU 8%, fixed multiply (MRF+=SSI) 2%. RECIPS and RSQRTS appear. 108k delayed branches per
  1.24 M instructions.
- Idle: 73-78% of PC samples at the IDLE instruction in attract and play windows.

## Open RTL

| Chip | Existing HDL |
|---|---|
| PPC403GA | none. Microwatt (Apache-2.0, VHDL) is 64-bit Book III-S; reference only |
| ADSP-21062 | none |
| Voodoo 1 | SpinalVoodoo (github.com/fayalalebrun/SpinalVoodoo), runs on a DE10-nano per its README; **no licence** (GitHub `license: null`) |
| RF5C400 | none; jotego `jtpcm568` (RF5C68) and MegaCD `PCM.vhd` (RF5C164) are structural references |
| K037122, K033906, K056800 | none |
| 68000 | fx68k, shipped in MiSTer cores |

Searched by chip and by board (Hornet, NWK-TR, Firebeat for the PPC403; Model 2B for the SHARC);
nothing found.

## PPC403 core standalone (`rtl/synth_check/`)

Quartus 17.0.2 Lite, 5CSEBA6U23I7, seed 0, 64 MHz constraint, inputs from an LFSR, outputs
folded to one pin. The multi-cycle core of commit 2ffa825:

| | Used | Of 5CSEBA6 |
|---|---|---|
| ALMs | 9,608 | 23% |
| Registers | 2,902 | |
| M10K | 0 | |
| DSP | 3 | 3% |

Fmax 62.64 MHz (slow 1100 mV 100C), setup slack -0.338 ns at 64 MHz. The twelve worst paths all
run `ir[rA]` -> GPR read -> effective address -> exception decision -> `pc` in one cycle.

## Feasibility

Open. What the measurements above require, and what closes each:

1. **PPC403: about 32 MIPS at peak** (play reaches 100% busy at 32 MHz). The core in
   `rtl/cpu/ppc403/` takes 5.97 clocks per instruction on the boot RAM test with one-clock memory
   (`sim/ppc_tb`); at 64 MHz that is 10.7 MIPS. It needs about 2 clocks per instruction, or
   pipelining, plus an instruction cache. Closed by CPI on game code and standalone Fmax.
2. **SHARC: one instruction per 36 MHz clock at peak** (93% busy). A pipelined core with a
   single-cycle float multiply and add; nothing multi-cycle fits. `rtl/cpu/sharc/` takes 1.45 and
   2.05 clocks per instruction on windows 3000 and 7500 (`sim/sharc_tb`, zero-wait external bus).
   Closed by a standalone synthesis of its execute clock.
3. **Voodoo fill: peak 590k triangle pixels + 393k fastfill pixels per frame.** Frame-buffer
   traffic at 8 B per blended, depth-tested pixel and 4 B per fastfill pixel is about 6.3 MB per
   frame, 366 MB/s, plus 23 MB/s scanout; uncached bilinear texels would add up to 274 MB/s.
   Within one 64-bit DDR3 port's peak (about 1 GB/s at 125 MHz, inferred, not measured), but the
   accesses are latency-bound. Closed by a DDR3 throughput test on the board.
   Measured on SpinalVoodoo (`sim/voodoo_tb`, frame 2150, zero memory latency): 1.05M clocks for
   1,200 triangles, 418k triangle pixels and a 196k-pixel fast fill, about 0.6 triangle pixels a
   clock after the fill; 16.4 ms at 64 MHz against MAME's 10.8 ms for the SHARC's whole job. The
   author's DE10 build runs at 50 MHz (hw/de10/qsys/create_de10_core_pll.tcl). At 64 MHz the
   board falls a frame behind in attract (`sim/board_tb`, ROADMAP Progress).
4. **Voodoo RTL**: SpinalVoodoo's licence, or the cost of writing the rasteriser.
5. **Area**: three cores of this size on a 5CSEBA6 (41,910 ALMs = 83,820 ALUTs, 553 M10K =
   5.66 Mbit, 112 DSP) with the framework. Whole-board synthesis (`rtl/synth_board`, Quartus
   17.0.2, no `sys/`): 253,486 ALUTs, 105,501 registers, 4.81 Mbit, 99 DSP; three times the ALUTs.

   | Block | ALUTs | Registers | Block bits | DSP |
   |---|---|---|---|---|
   | SHARC (`sharc_core`) | 176,409 | 9,461 | 2,031,616 | 34 |
   | Voodoo (`CoreHornet`) | 46,848 | 46,249 | 610,864 | 62 |
   | Video (`hornet_video`) | 15,354 | 36,001 | 0 | 0 |
   | PPC (`ppc403_core`) | 8,250 | 2,830 | 0 | 3 |
   | Board glue and RAMs | 4,949 | 10,786 | 2,162,688 | 0 |

   The SHARC is the transcription of MAME's interpreter: the whole instruction in one
   combinational clock over a copied state struct. The video's line buffers and the board's
   K033906 RAM and K037122 registers were built as registers. Fmax not measured (no fit).

   Fits since (5CSEBA6, Quartus 17.0.2, 64 MHz constraint):

   | Block | ALMs | Registers | DSP | Fmax | Source |
   |---|---|---|---|---|---|
   | SHARC v2 (`rtl/synth_sharc`, commit 91bf000) | 33,984 | 13,201 | 5 | 29 MHz | docs/SHARC_V2.md |
   | Voodoo, Gradius IV subset (patch 0004 options) | 26,489 | 38,031 | 46 | 55 MHz | below |
   | PPC (`ppc403_core`) | 5,896 | 2,920 | 3 | 64.2 MHz | Konami M2 session's fit |
   | sys/ (sibling cores: Seta 20,885 - 14,137, Fuuki 16,446 - 9,545) | ~6,800 | | | | fit reports |

   The Voodoo subset (`hornet.CoreHornetTrimGen --no-fb-cache --fixed-lod --formats 0,10,12`:
   no fog, 512x384, no framebuffer read cache, LOD from tLOD's clamp, RGB332/RGB565/ARGB4444)
   takes the standalone map from 43,587 to 38,786 ALUTs; the rest is machinery the game uses
   (TMU 8.6k own ALUTs, TriangleSetup 6.4k, SpanWalker 6.3k, texture cache 5.1k, register bank
   4.2k with 9.5k registers). Voodoo + PPC is 32.4k ALMs of the ~35.1k the board can have beside
   sys/, before the SHARC, video and glue: the board does not fit the device as built.
