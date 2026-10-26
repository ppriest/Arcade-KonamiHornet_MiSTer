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
| 68000 | Musashi, on the HPS | MiSTer_ArcadeSoundServer's `PROVENANCE.md` |
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

**Phase 3 — Sound. Done** (`2779c02`): the sound board on the HPS (`sw/arcsnd`, now the MiSTer_ArcadeSoundServer project; Musashi and
MAME's RF5C400 and K056800), fed through DDR3 by `rtl/mister/hornet_sndbridge.sv`; the FPGA had
no room for fx68k. Heard on the DE10-nano.

**Phase 4 — nbapbp and the clones.** JVS for nbapbp.

**Phase 5 — Savestates.** Optional; state kept reachable from Phase 1 (`docs/STATE.md`).

## Open items

**Walking robots walk in the air (stage 4's rocky section, before the lava).** They should fall to
the ground (user report on the DE10-nano, build 30000031). Game logic, not drawing: the Voodoo
window at frame 39600 draws the same with and without the day's vraster changes. Not yet
compared with MAME's object state.


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

## Area plan (proposed; no step starts before the user approves it)

Goal: free ALMs for the Voodoo speedups the device cannot hold (16 line-buffer sets, about 395
ALMs, 513k to 439k busy clocks for 44400's second frame in `board_tb`; the span-start
multipliers, 108 ALMs and 8 DSP) and for fitter headroom (at 99% the HDMI scaler's clock misses
at every seed), without adding a clock to the SHARC's hot instructions or to vraster's pixel rate.

Where the 41,568 ALMs are (release `45da077`, seed 9, `KonamiHornet.fit.rpt`):

| Block | ALMs | Note |
|---|---|---|
| `sys/` | ~7,100 | fixed: ascal 2,049, audio 874 (ALSA is the sound server's path), two OSDs 988, pll_hdmi_adj 539, hps_io 486 |
| `sharc2_core` | 16,702 | own 11,914, ALU 4,120, RAMs and MLABs 670; 5 DSP |
| `vraster` | 6,973 | 67 DSP; written for area, the fill rate is the frame-rate bottleneck |
| `ppc403_core` | 3,343 | |
| `hornet_video` | 1,984 | AREA already |
| `hornet_board` glue | 1,941 | |
| `hornet_sdram`, `hornet_ddr3`, icache, sndbridge, rtc, loader | 2,642 | 1,008 / 730 / 418 / 214 / 173 / 99 |

What the SHARC's logic is (`rtl/synth_sharc/area_exp.py`, quartus_map of the core alone,
`area_round4.txt`; base 29,683 ALUTs, own 21,432, ALU 7,657): the XS_STEP path 4,514, the DMA
engine 2,385, IOP register writes 1,674, op_fuse 1,578, get_ureg 1,128, the loop end 505, the
fetch-step interrupt 196. DMA_PACK 0 took 506 (shipped).

What the game needs (HARDWARE_NOTES, "Program census"): the hot forms are compute with a DM
access, ureg moves among R/I/M/L/USTAT/IRPTL/MODE1, sysreg bit ops on those four registers,
immediate shifts, jumps, calls and returns; 99.3% of the play trace. Never used: type 1 dual
access, PUSH/POP, FAVG and a dozen other compute ops. Boot only: PM-bus data, PX.

### Steps

Each step: parameterised in the core (the benches keep the full core), `sim/sharc2_regress.sh`
(windows 195, 216, 3000, 7500, serial and pipelined), `board_tb` frames 2150, 7500, 3900 and
44400 keep step, `build_staged.py`, hardware. Savings are estimates until step 0 measures them.

0. **Measure.** Knockout variants in `area_exp.py` for each item below; the same harness for
   vraster, hornet_video and the board glue in `rtl/synth_board`; a trace check that no
   post-modify ran with L != 0 (the trace has I/M/L per line) before the circular-buffer wrap goes.
1. **The game's subset of the compute units** (parameter): FAVG (679 ALMs standalone,
   SHARC_V2), the unused slow ops, shifter ops and multifunction forms, type 1, PUSH/POP.
   About 800 ALMs.
2. **Dual FADD/FSUB through one adder**, two passes (312 per 2M instructions, +2 clocks each):
   the second `sharc_fadd` goes, about 450 ALMs.
3. **Loop and status stacks in MLAB** with pointers, as the PC stack: 704 flops and their
   push/pop muxes, about 350 ALMs.
4. **DMA parameter registers in MLAB**: the 16 IOP registers written one at a time by
   `iop_write` and read by the engine when a channel starts (1,763 starts a frame, a few clocks
   each); widths to the chip's (C/EC 16, II 17, CP 18 bits); GP and the host port dropped.
   400-600 of the engine's 1,200 ALMs.
5. **Hot and cold universal registers**: `get_ureg`/`op_ureg` hardwired for R, I, M, L, USTAT1,
   USTAT2, IRPTL and MODE1 (every source above 0.01% of the trace); the rest through step 6.
   300-500 ALMs.
6. **A microcoded sequencer for the cold work**, replacing XS_STEP, `x_rq` and `todo`: one 32-bit
   universal-register read and write path, one stack port, a few primitive ops, the program in one
   or two M10K (freed from the icache's tags, which belong in MLAB: it holds 6 M10K for 8,704 bits).
   It runs DO UNTIL, the loop end's pops, a call's push, RTS/RTI, interrupt entry, IOP writes,
   cold ureg writes (MODE1, IMASK, PCSTK, LCNTR, ...), PM-bus data and PX (boot), IDLE, L and B
   writes. The hot forms keep their one handler clock. Net 1,000-2,000 ALMs (the step path alone
   is 4,514 ALUTs); the largest and riskiest step, after 1-5 are built and measured.
7. **Spend it**: SB 4 (16 sets), the span-start multipliers, and a utilisation that meets the
   HDMI clock across seeds. The SHARC's clk_dsp slack (+0.453) is re-checked after each step.

Target: at least 2,000 ALMs from steps 1-5, 1,000 more from 6.

### Results

quartus_map of `sharc2_core` alone (`rtl/synth_sharc/area_exp.py`, `area_round5.txt`), combinational
ALUTs; each step passed the window benches and kept `board_tb`'s four logs identical to `136a2d1`'s
(window 216 stops at a device divergence at instruction 82,649 in both):

| Step | Commit | ALUTs | Registers | Note |
|---|---|---|---|---|
| before | `136a2d1` | 25,830 | 6,590 | |
| 1 subset | `ba7f7b1` | 22,728 | 6,348 | knockouts: type 1 1,543, FAVG 1,216, multifunction 438, fixed ALU 415, shifter 132 |
| 2 one adder | `b2dee41` | 22,028 | 6,263 | window 7500: +42 unit-busy clocks, total unchanged |
| 3 stacks in MLAB | `7d22886` | 21,363 | 5,585 | |
| 4 DMA registers | not built | | | upper bound 326 ALUTs (registers never written) |
| 5 cold ureg reads | built, reverted | 21,325 | 5,618 | the mux moved to the holding register's input: 38 ALUTs |
| 6 microcode | not built | | | the whole XS_STEP path is 1,308 ALUTs now; a sequencer keeps the micro-ops' datapath |

On the current core the DMA engine is 2,139 ALUTs and get_ureg 818. A sequential (microcoded) DMA
engine would cost the board its word-a-clock Voodoo transfers, which bind in busy frames (44400:
30,445 idle SHARC clocks a frame).

Step 7: SB 4 (`adc8921`), 44400 frame 2 563k -> 448k Voodoo busy clocks in `board_tb +ddr3`.

Full builds (`build_staged.py`, seed 9), against the release `45da077` (41,568 ALMs; SHARC 16,702):

| Commit | ALMs | SHARC | vraster | clk_sys | clk_dsp | HDMI |
|---|---|---|---|---|---|---|
| `b2dee41` (steps 1, 2) | 39,163 | 14,946 | 7,025 | +1.172 | +0.132 | -0.152 |
| `9abfd5f` (1-3, SB 4) | 39,251 | 14,622 | 7,499 | +0.278 | +0.964 | -0.304 |

`9abfd5f` is on the board as `KonamiHornet_30000040.rbf`. Attract, a native screenshot a second
with the slowdown indicator on (`scripts/hw_slowdown.py`, `debug/hw/slow40/long40` and `long39`):
the lava demo (the scene of snapshot 44400, a fixed number of game frames) takes 28 s against
`30000039`'s 32 s, with the indicator on for 20 of those seconds against all 32; the attract's other
indicator events (fades and GAME OVER cards, where the game itself swaps slowly) fall at the same
seconds on both builds. At `74bb49a` (the same RTL
before the slow unit's sources were preserved) clk_dsp failed by 0.632 ns (LESSONS_LEARNED: retiming).

### Not in the plan, and why

- **vraster**: the pixel pipeline is a pixel a clock and already shares one setup multiplier and a
  sequential edge divider; the triangle gradients come from the SHARC's program, so HyperNG64's
  setup-in-microcode has no counterpart here. Knockouts in step 0 may find a few hundred ALMs in
  the command processor; nothing touches the pixel path.
- **PPC**: a sequencer for lmw/stmw, strings, dcbz and exceptions is possible (300-600 ALMs,
  unmeasured); after the SHARC, if still needed.
- **hornet_video, glue, SDRAM, DDR3**: step 0's knockouts first; only an avoidable item above
  about 300 ALMs is worth a change (candidates: the CLUT table rebuild, the port A read mux, the
  cheat engine).
- **sys/**: YC, adaptive scanlines and the downscale filter are already off; ALSA stays.
- Translating the SHARC program itself into microcode for a smaller engine: the program is the
  game's, loaded and checked by the PPC; not considered.
