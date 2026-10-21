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
  the Voodoo (`vraster`), started from MAME's whole board at frame 7500 and run freely. Buffer
  swaps follow MAME's on frames 7501-7504; the frames the board rendered differ from MAME's in
  5, 17 and 13 of 196,608 pixels (`debug/board7500_vraster.log`; with SpinalVoodoo it was
  5,331-5,415). One frame is about 95 s of Verilator.
- Picture (`rtl/board/hornet_video.sv`): the Voodoo's displayed buffer through its CLUT under the
  K037122 rotate/zoom tilemap, a line built during the one before. Against MAME's screen: frame
  7501 0 of 196,608 pixels differ, 7502 5,378, 7503 5,310 (the Voodoo's differences;
  `docs/screenshots/board/frame7503_mame_board_screen.png`). The K037122 in these frames is the
  unrotated HUD; gradius4 never rotates or zooms it (`scripts/mame_k037122_scan.py`, frames
  0-8400: increments fixed at 1.0 from frame 148).
- Attract snapshot (frame 2150, `debug/gradius4-board2150`): with vraster the board keeps step
  with MAME's buffer swaps over four frames, 0/150/124/138 pixels differing
  (`debug/board2150_vraster.log`). With SpinalVoodoo it fell a frame behind: 1.05M clocks for
  frame 2150's triangles and fast fill at zero memory latency.
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

Built: clk_sys 64 MHz for the board, video, SDRAM (CL2, SDRAM_CLK at 180 degrees) and DDR3;
the SHARC on its own clk_dsp, 48 MHz (user decision: in the full design the SHARC closes about
50 MHz, the rest of the board needs 64), crossing to the board in `hornet_board` through
`hornet_cdc`. Frame 2150 keeps step with it in `sim/board_tb +dspmhz=48` only with the Voodoo's
memory FIFO (a 64K-entry ring in DDR3, `vraster`): the 2048-entry FIFO alone needs the SHARC at
60 MHz.

## Component reuse map

| Block | Plan | Source |
|---|---|---|
| PPC403GA | written from MAME's model | `src/devices/cpu/powerpc/` |
| ADSP-21062 | written from MAME's model | `src/devices/cpu/sharc/` |
| Voodoo 1 | SpinalVoodoo, generated Verilog vendored; no binary release while unlicensed (user decision) | github.com/fayalalebrun/SpinalVoodoo (no licence) |
| K037122 | written from MAME's model | `src/mame/konami/k037122.cpp` |
| K033906, konppc glue | written from MAME's model | `k033906.cpp`, `konppc.cpp` |
| 68000 | Musashi, on the HPS | `sw/arcsnd/PROVENANCE.md` |
| RF5C400 | MAME's, on the HPS | `src/devices/sound/rf5c400.cpp` |
| K056800, M48T58, X76F041 | written from MAME's model | device files |

## Design decisions

**No standard-feature work for this core (user decision).** Flip screen, HDMI rotation, HDMI
scaling and crop, CRT Adjust, hiscore and audio mix are out: the device has no room, and the effort
goes to the frame rate and sound. `rtl/mister/hornet_rotate.sv` stays in the tree, unbuilt
(`MISTER_FB` off).

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

**Phase 2 memory plan** (draft; the SDRAM top's header will be the authority once written):

| What | Size | Where | Why |
|---|---|---|---|
| PPC work RAM | 4 MB | SDRAM, port A | the PPC's loads and stores; latency-bound |
| PPC program ROM, data ROM | 2 + 4 MB | SDRAM, port A | instruction fetch and table reads |
| K037122 character RAM | 2 MB | SDRAM, port A writes, port C reads | the video reads it per pixel group |
| SHARC RAM at 0x500000, 0x1400000 | up to 4 MB each | SDRAM, port B | the SHARC's external bus |
| CG ROM | 16 MB | SDRAM, port B | the SHARC's direct reads, texture source |
| Voodoo frame buffer and depth | 2 MB (4 MB window) | DDR3 | six vraster masters and scanout (port S); bandwidth, not latency |
| Voodoo texture memory | 4 MB | DDR3 | vraster's tile fills, burst reads |
| shared RAM, K037122 SRAM, M48T58, K033906 | 128 + 96 + 8 + 1 KB | block RAM | already on chip |

SDRAM: 28 MB of the 128 MB, three ports (A PPC, B SHARC, C video) on the burst-4 controller the
prior cores share. DDR3: the Voodoo's 8 MB window and the ROM fast-load path.

Throughput at 64 MHz, measured in `sim/board_tb` on frame 2150 (the heaviest snapshot; it must
keep step with MAME's buffer swaps):

- The PPC keeps step at port A latency 10; its spare time is idle loop.
- Port B's traffic is the RAM at 0x1400000, 16,337 reads a frame, 16,294 of them sequential
  (`+bstat`). Plain latency 6 falls a frame behind; behind a two-line read-ahead buffer filled at
  two clocks a word (`+bcache +bwpc=2`) latency 12 keeps step.
- The Voodoo keeps step at DDR3 latency 24 with 4 reads outstanding a port and the 2048-entry
  command FIFO (RASTER.md); it falls behind at 56 MHz. Its traffic is 568k 32-bit beats a frame
  (`+vstat`), plus 98k for the picture: about 30% of the clocks as 64-bit beats.
- Ports C and S as one word a request overrun lines from latency 2: port C goes behind a cache,
  port S becomes a burst a row.

Built:
- `rtl/mister/hornet_sdram.sv`: ports A, B, C and the download on Sorgelig's controller at
  128 MHz, CL3 (port C's 128-line cache, port B's read-ahead, port A's last granule;
  `sim/sdram_tb`).
- `rtl/mister/hornet_ddr3.sv`: vraster's six masters and port S on the 64-bit DDRAM port,
  32-bit beats packed in pairs (`sim/ddr3_tb`).
- `hornet_video`: port S a 256-word burst a line, port C a tile row a request, the K037122 row
  a pixel a clock; every line built in time in `board_tb` with each row fetch at 22 clocks.
- `KonamiHornet.sv`: PLL, download (`releases/Gradius IV Fukkatsu (ver JAC).mra`, from
  `scripts/gen_mra.py`), DIPs, inputs, Pause, video.
- `hornet_icache.sv`: the PPC's 1 KB instruction cache; without it the PPC falls a frame behind
  in game at port A latency 10.

Core builds (`scripts/build_staged.py`, with `sys/` and physical synthesis), clk_sys at 64 MHz:

| Commit | ALMs | M10K | Worst setup | Where |
|---|---|---|---|---|
| aa13328 | 38,763 (92%) | 545 | -4.64 ns; SDRAM capture -2.85 | SHARC X: operand, compare, R write; SDRAM at 128 MHz |
| 4f9a01f | 39,287 (94%) | 547 | -5.06 | SHARC X (SDRAM now on clk_sys, capture met) |
| 56ca359 | 41,452 (99%) | 547 | -19.78 | congestion (bilinear in logic: reverted) |
| da58b00 | 39,863 (95%) | 548 | -3.79 | SHARC X: flags, condition, PC stack; PPC -1.62 |
| b2bec60 | 39,427 (94%) | 550 | -4.51 | SHARC: 96% of the 9,833 failing endpoints |
| aa8e43a | (96%) | 549 | no fit | the SHARC on clk_dsp, the memory FIFO: routing failed |
| a29b0c6 | 38,486 (92%) | 541 | met: clk_sys +1.379, clk_dsp (48 MHz) +0.346, hold met | PPC GPRs in MLABs, the SHARC on its own clock |

On the DE10-nano (`KonamiHornet_stp` at `4376611`): boot, attract, title screen as MAME's
(`docs/screenshots/gradius4/title.png`), a game starts; the M48T58 saved to the `.nvm`. Probe H at
the title: no unbuilt K037122 lines, port C 20.3 clocks a request on average, 66 at worst.

At `a034e0d` (wide DDR3 masters, texture fill runs; `KonamiHornet_stp`): attract at 1,834 buffer
swaps over 1,882 displayed frames (probe H, 11 reads in 32 s), 97% of 58.36 Hz; 9 a second
before. In-game sections still slow down (user report). DDR3 read latency on the board: 15
clocks on average, 174 at worst (probe D).

Open: play-through on hardware, release-revision timing (the HDMI scaler clock by picoseconds; a
clk_sys hold path in the last stp build), flip screen, fast ROM loading, the security EEPROM and
JVS (gradius4's boot does not select the X76F041).

**Phase 3 — Sound. Done** (`2779c02`): the sound board on the HPS (`sw/arcsnd`, Musashi and
MAME's RF5C400 and K056800), fed through DDR3 by `rtl/mister/hornet_sndbridge.sv`; the FPGA had
no room for fx68k. Heard on the DE10-nano.

**Phase 4 — nbapbp and the clones.** JVS for nbapbp.

**Phase 5 — Savestates.** Optional; state kept reachable from Phase 1 (`docs/STATE.md`).

## Open items

**SpinalVoodoo has no licence (GitHub `license: null`).** The board no longer uses it (vraster
replaced it); `rtl/voodoo` stays as the earlier reference until removed. The repository stays
private (user decision).

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
   gives 31 M. v1 synthesises to 126k ALUTs (HARDWARE_NOTES Feasibility 5): rewrite as a
   pipelined v2 (user decision), plan in `docs/SHARC_V2.md` (latency model: 1.535 CPI at float
   latency 2, 41.7 MIPS at 64 MHz).
   v2 is MAME-exact (SHARC_V2.md Status) but 41.6k ALUTs at 29 MHz; with the Voodoo it does not
   fit (HARDWARE_NOTES Feasibility 5). Next for it: a hand-built X sequencer (12-15k ALUTs, 64 MHz).
7. Fit: SpinalVoodoo for Gradius IV's subset is 26,489 ALMs; with the PPC it fills the board's
   ~35k ALMs beside sys/. User decision: replace it with an own Voodoo 1 subset rasteriser written
   for area from MAME's model, plan in `docs/RASTER.md`. Done: `rtl/raster/vraster.sv`, in the
   board in place of CoreHornet. Standalone (`rtl/synth_raster`): 6,688 ALMs, 81 M10K, 64 DSP;
   Fmax 69.2 MHz (slow 100C), 66.8 MHz (slow -40C).
   First whole-board fit (`rtl/synth_board`, SHARC v2 and vraster, without sys/): does not fit.
   Logic 46,896 ALMs estimated (hornet_video 11,558, SHARC 19,009, vraster 6,311, PPC 4,360,
   board 1,977); block RAM needs more than 553 M10K at 83% of the bits: the three 32K x 32
   dual-port RAMs (u_ksram, u_shram, the SHARC's DM) take about 128 blocks each.
   After hornet_video's line buffers were instanced (Quartus had built one from registers) and the
   SHARC's DM was sized to what the game uses (16K words, HACKS): the board fits alone, 40,544
   ALMs (97%), 507 M10K, 48.4 MHz (SHARC 23,794, vraster 6,533, PPC 6,083, video 1,873). sys/
   (Fuuki's fit: about 6,900 ALMs, 56 M10K) does not fit beside it yet. `sim/vraster_tb`: windows 2150/7500/3000 differ from
   MAME in 150/5/0 pixels (HACKS); at 20 clocks memory latency, 8 bursts outstanding, frame 2150
   takes 703k clocks and 7500 531k.
6. Board integration in simulation (Phase 1): the in-game snapshot runs and its picture matches;
   with vraster both snapshots keep step with MAME's buffer swaps (Progress). Booting: from a frame-140 snapshot
   the PPC starts the SHARC at frame 152 (MAME 151), its EPROM boot runs, and the upload check
   passes (the SHARC's 417 comm writes agree with MAME's, `scripts/mame_commlog.py`); pictures
   match to frame 159. From frame 195 the pictures match through 225 (two SHARC decode/flag bugs
   fixed on the way; the core had crashed on its self-modifying boot code at 218). From 625 they
   match to 646. With the M48T58 read 4 bytes a word (it had failed the NVRAM check and shown
   HARDWARE ERROR (0)) and a stand-in for the 68000's handshake (HACKS), the boot reaches attract:
   "CREDITS 00" from frame 647, where MAME shows it from 683 (its PPC waits on the SHARC in
   between; cause of the 36 frames unverified). The JVS start-up at 222-458 waits 2 s a try, as in
   MAME (`scripts/mame_bootlog.py`).
