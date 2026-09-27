# Konami Hornet — MiSTer Core Roadmap

**The user directed implementation to start before this roadmap was reviewed. The phase order
below is a proposal; a phase whose scope changes goes back to the user.**

## Context

Goal: a DE10-nano MiSTer core for Konami's Hornet board, first target Gradius IV (`gradius4`),
emulated by MAME's `konami/hornet.cpp` and the devices it instantiates — a Quartus 17.0.2 project
producing one `.rbf` and a `.mra` per supported set.

**Nothing on this board has open RTL except the sound CPU** (fx68k). Everything else is written
from MAME's model:

1. PowerPC 403GA main CPU.
2. ADSP-21062 SHARC geometry DSP.
3. 3dfx Voodoo 1 rasteriser, unless SpinalVoodoo's author grants a licence.
4. K037122 tilemap, K033906 PCI shim, K056800 sound mailbox, RF5C400 PCM.

Whether it fits one DE10-nano is open: `HARDWARE_NOTES.md`, "Feasibility". Phase 0 is the gate
that answers it.

Background and sources for every number: [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).

## Progress

**Phase 0 in progress: the PPC403GA core matches MAME instruction for instruction on boot,
attract and gameplay code.**

- `rtl/cpu/ppc403/ppc403_core.sv`, bench `sim/ppc_tb`, diff `scripts/compare_insn_trace.py`.
- From reset (`scripts/mame_insn_trace.py`): 1,000,000 of 1,000,000 instructions agree in PC
  and 37 registers (the boot RAM test).
- Windows (`scripts/mame_ppc_window.py`: MAME state and work RAM at a frame, device reads,
  interrupts and timebase reads replayed): frame 3000 (attract) 743,505 of 743,505; frame 7500
  (stage 1) 2,000,000 of 2,000,000.
- PPC pipelined: 1.75-1.94 clocks per instruction at one-clock memory, 5,911 ALMs standalone
  (HARDWARE_NOTES); the last timing run did not finish.
- SHARC (`rtl/cpu/sharc/`, bench `sim/sharc_tb`, `scripts/compare_sharc_trace.py`, windows from
  `scripts/mame_sharc_window.py` with MAME's whole saved state): frame 3000 300,000 of 300,000,
  frame 7500 2,000,000 of 2,000,000 instructions agree in PC and 56 registers. Clocks per
  instruction with the bench's zero-wait external bus: 1.45 (window 3000), 2.05 (window 7500,
  DMA active for about half its instructions). One execute clock holds the whole instruction,
  float multiply and add included; its Fmax is not measured (no Quartus runs for now).
- SHARC floating point (`sharc_fp_pkg.sv`): 9.2 M vectors bit-exact against MAME's host-float code.
- SpinalVoodoo (`rtl/voodoo/spinalvoodoo`, bench `sim/voodoo_tb`, captures from
  `scripts/mame_voodoo_window.py`): one frame replayed from MAME's state and the SHARC's writes.
  Two texture fill-cache bugs fixed by patch (`rtl/voodoo/spinalvoodoo/PROVENANCE.md`); every
  texel fetched now matches texture memory (`sim/voodoop_tb` texel check). 2x2 dither switched to
  MAME's matrix (MAME_KLUDGES). Drawn buffer against MAME: frame 2150 (demo) 4,613 of 196,608
  pixels differ; frame 7500 (stage 1 boss) 5,381, of which 268 by 8 or more per channel, isolated
  pixels of small triangles (`scripts/voodoo_diff_by_state.py`). Grabs:
  `docs/screenshots/voodoo/frame{2150,7500}_mame_core_diff.png`. Remaining differences accepted
  (HACKS).
- Board in simulation (Phase 1, `rtl/board/hornet_board.sv`, bench `sim/board_tb`, snapshot from
  `scripts/mame_board_snapshot.py`): PPC, SHARC, shared RAM, comm, sysreg, M48T58, K033906 and
  the Voodoo (`CoreHornet`), started from MAME's whole board at frame 7500 and run freely. Buffer
  swaps follow MAME's on frames 7501-7504; the three frames the board rendered differ from MAME's
  in 5,331-5,415 of 196,608 pixels, the Voodoo's accepted differences
  (`docs/screenshots/board/frame7504_mame_board_diff.png`). One frame is about 95 s of Verilator.
- Picture (`rtl/board/hornet_video.sv`): the Voodoo's displayed buffer through its CLUT under the
  K037122 rotate/zoom tilemap, a line built during the one before. Against MAME's screen: frame
  7501 0 of 196,608 pixels differ, 7502 5,378, 7503 5,310 (the Voodoo's differences;
  `docs/screenshots/board/frame7503_mame_board_screen.png`). The K037122 in these frames is the
  unrotated HUD; gradius4 never rotates or zooms it (`scripts/mame_k037122_scan.py`, frames
  0-8400: increments fixed at 1.0 from frame 148).
- Attract snapshot (frame 2150, `debug/gradius4-board2150`): frame 7501-equivalent matches (0
  pixels); from the next frame the board is one frame behind MAME. The SHARC's frame job runs
  about 525 lines (MAME: 10.8 ms, `scripts/mame_commlog.py`) because it waits 764k of 1.1M clocks
  on the Voodoo's command FIFO: SpinalVoodoo needs 1.05M clocks for frame 2150's 1,200 triangles,
  418k triangle pixels and one 196k-pixel fast fill, with zero memory latency (`sim/voodoo_tb`
  +memlat=0). In play (7500) the wait is about 520k clocks a frame and the frame still fits.
- Workload measured in MAME (`scripts/hornet_load.py`): HARDWARE_NOTES, "Measured workload".

## Game scope

| Set | Config | MAME status | Plan |
|---|---|---|---|
| gradius4 + 5 clones | `hornet_x76` | working | first target |
| nbapbp + 7 clones | `nbapbp` (adds JVS) | working | second target |
| terabrst, thrilld, sscope, sscope2 families | GN680 / LAN / two boards / Voodoo 2 | NOT_WORKING | out of scope |

## Clocks

| Clock | Rate | Source |
|---|---|---|
| PPC403GA | 32 MHz (64 MHz / 2) | hornet.cpp:1394 |
| 68000 | 16 MHz (64 MHz / 4) | hornet.cpp:1403 |
| SHARC | 36 MHz | hornet.cpp:1407 |
| Voodoo | 50 MHz | hornet.cpp:1418 |
| RF5C400, K056800 | 16.9344 MHz | hornet.cpp:1438, 1443 |
| pixel | 16 MHz (64 MHz / 4), 644 x 428 total | hornet.cpp:1432 |

**Provisional `clk_sys` = 64 MHz**, 4x the pixel clock and the board's own crystal. Enables: PPC
timebase 1/2, 68000 1/4, pixel 1/4 (all exact); SHARC 9/16; Voodoo 25/32; RF5C400 16.9344/64 =
0.2646 exactly (Bresenham). SDRAM at 128 MHz (2x).

96 MHz (6x) is the alternative if the PPC or SHARC cannot meet the board's throughput at 64 MHz;
it costs timing margin. Decided by Phase 0 criteria 3 and 4.

## Component reuse map

| Block | Plan | Source |
|---|---|---|
| PPC403GA | written from MAME's model | `src/devices/cpu/powerpc/` |
| ADSP-21062 | written from MAME's model | `src/devices/cpu/sharc/` |
| Voodoo 1 | SpinalVoodoo, generated Verilog vendored; no binary release while unlicensed (user decision) | github.com/fayalalebrun/SpinalVoodoo (no licence) |
| K037122 | written from MAME's model | `src/mame/konami/k037122.cpp` |
| K033906, konppc glue | written from MAME's model | `k033906.cpp`, `konppc.cpp` |
| 68000 | fx68k | a MiSTer core's `rtl/FX68K`, to be located and read before vendoring |
| RF5C400 | written from MAME's model; jtpcm568 as structure | `src/devices/sound/rf5c400.cpp` |
| K056800, M48T58, X76F041 | written from MAME's model | device files |

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is**
(`docs/MAME_KLUDGES.md`).

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands.

**The Voodoo draws into a frame buffer**, because the board has one: 2 MB of frame-buffer RAM
(hornet.cpp:1419). It lives in DDR3 with the depth buffer; the scaler reads the front buffer.

**The CPU cores are verified by instruction-trace diff against MAME before any bus work**, then by
bus-access diff with device reads replayed from MAME.

## Phased roadmap

**Phase 0 — the three processors standalone, and the feasibility gate.**

1. PPC403GA matches MAME's instruction trace through boot to the attract loop, device reads
   replayed from MAME. — Open: 1,000,000 boot instructions match; device replay not built.
2. PPC CPI measured on game code with a realistic memory model; the clock plan follows.
3. SHARC core matches MAME's instruction trace on the geometry kernel. � Met for frames 3000 and
   7500 (above); DMA timing and IRQ entry replayed from MAME's trace.
4. Standalone Fmax and area for the PPC and the SHARC at this project's settings.
5. Voodoo: licence answer for SpinalVoodoo, or a rasteriser plan; DDR3 throughput measured on
   the board with a synthetic frame-buffer pattern.

Exit: the user decides, from 2-5, whether the board fits and at what scope.

**Phase 1 — The board in simulation.** PPC + SHARC + shared RAM + comm + K037122 + Voodoo in
Verilator, reaching attract frames that match MAME's snapshots.

**Phase 2 — Hardware bring-up.** SDRAM/DDR3 map, ROM download, `.mra`, inputs, DIPs, NVRAM and
the security EEPROM, the standard feature set. Silent.

**Phase 3 — Sound.** fx68k, K056800, RF5C400.

**Phase 4 — nbapbp and the clones.** JVS for nbapbp.

**Phase 5 — Savestates.** Optional; state kept reachable from Phase 1 (`docs/STATE.md`).

## Open items

**SpinalVoodoo has no licence (GitHub `license: null`).** User decision: the core uses it, and no
binaries are released while it stays unlicensed. The repository stays private. A release needs the
author's grant or a rasteriser written here.

**The MAME binary (0.289) and the source read (mame0289-661) differ.** No 0.289-661 full build
exists on this machine (`E:/mame/mame.exe` is a subtarget without Konami). The PPC, SHARC and
Voodoo files are to be diffed between the two tags before a divergence is blamed on either.

## Next steps

1. ~~MAME device-read capture and replay for the PPC bench.~~ Windows at frames 3000 and 7500.
2. ~~Pipelined PPC.~~ 1.75 clocks per instruction; timing at 64 MHz re-checked once Quartus may run.
3. ~~SHARC core against MAME's trace.~~ Frames 3000 and 7500 match.
4. ~~SpinalVoodoo against MAME.~~ Texture-cache bugs fixed, MAME's 2x2 dither; the remaining
   differences are accepted (HACKS).
5. SHARC speed: 7.69/9.21 -> 1.45/2.05 clocks per instruction (windows 3000/7500). The peak
   load needs about 33.5 M instructions a second (HARDWARE_NOTES "Feasibility"): 64 MHz at 2.05
   gives 31 M. Open: the execute clock's Fmax (Quartus), then pipelining execute if it misses.
6. Board integration in simulation (Phase 1): the in-game snapshot runs and its picture matches;
   the attract snapshot falls a frame behind on Voodoo throughput (Progress). Decision needed:
   the Voodoo at a faster clock of its own, or a faster SpinalVoodoo pixel pipeline
   (HARDWARE_NOTES, Feasibility 3); parked (user decision). Booting: from a frame-140 snapshot
   the PPC starts the SHARC at frame 152 (MAME 151), its EPROM boot runs, and the upload check
   passes (the SHARC's 417 comm writes agree with MAME's, `scripts/mame_commlog.py`); pictures
   match to frame 159. Next: the rest of the boot (serial port set-up at 222, sound handshake at
   634, `scripts/mame_bootlog.py`).
