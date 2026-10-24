# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| SHARC block 0 is program memory only, block 1 data only | `rtl/cpu/sharc/sharc_core.sv` (`pm`, `dm`) | MAME stores both in one pair of arrays and lets data accesses reach block 0 and program accesses block 1; the game keeps code in block 0 and data in block 1 | Data-bus access to block 0 through the PM packing (sharc.cpp:299-330) | `scripts/sharc_profile.py`: 0 data words of block 0 touched in three windows | latent |
| Cheats applied once a frame, their off state not restored | `hornet_board.sv` (the cheat engine), `scripts/gen_mra.py` `mame_cheats` | MAME's cheats run their scripts every frame and restore on "off" (Invincibility patches code at 0x8021708B and restores it); the core writes each code's byte at vblank and keeps no copy, and a cheat with only an "on" script (Unlocked 2nd Loop Start) is written every frame too; a parameter cheat is one cheat a value | the old byte kept and written back when the code goes, and on-only codes written once | `board_tb +cheat=`: lives, options and an OR (missile) hold their values from frame 1 at frame 8460 | visible |
| SHARC DMA beside the instructions, not a quantum after each | `sharc2_core.sv` `DMA_LOCK` (0 on the board) | MAME moves one word per channel after each instruction, and the core's instruction end waited for that quantum (23% of the clocks of window 7500, `sim/sharc2_tb +pipe`); on the board an instruction ends while the engine works, and a quantum starts as soon as the last is done, so a DMA takes as many engine quanta as it needs but not as many instructions as MAME; there the engine also goes from word to word without an idle clock, asks for a word's external write in the clock it reads it, reads a TCB's words back to back, and reads a transfer's next word in the clock the last one's external write is acknowledged; a word to the Voodoo is posted (done when asked for) when the board's queue will take it next clock | the chip's own DMA timing (its I/O processor's cycles), from a hardware reference | `sim/board_tb` frame 3900: the swaps keep step with MAME's (59 and 43 pixels differ, as with lockstep) where lockstep missed frame 2's; 7500 unchanged; the window benches (`DMA_LOCK` 1) still match MAME | visible |
| SHARC host-port DMA (IOP 0x04) absent | `sharc_core_ops.svh` `iop_write` | not used by the game | Port `external_dma_write` | profile: no host-port DMA in the traced windows | latent |
| SHARC delayed IOP write counted in instructions | `sharc_core_ops.svh` `iop_write` | MAME fires it from a timer at a timeslice boundary, so no count matches | nothing on the MAME side; a hardware reference would say what the chip does | the window benches take DMA-status reads and IRPTL's DMA bits from MAME's trace instead | tooling |
| SHARC BR8, BR0, SRCU and SSE mode bits ignored | `sharc_core_ops.svh` `sysreg_latency_effect` | fatal or view-switching in MAME; not set by the game | Implement bit-reverse, alternate MR, short-word sign extension | MODE1 only ever 0x1000/0x1480 in the profile | latent |
| PPC403 privileged-instruction checks absent | `rtl/cpu/ppc403/ppc403_core.sv` | the game runs in supervisor state | Program exception 0x40000 on PR = 1 | MSR.PR never set in the traced windows | latent |
| Video line length is an input | `rtl/board/hornet_board.sv` `line_clocks` | MAME picks a 15.75, 25 or 31.5 kHz line rate nearest its current period (voodoo.cpp:2746-2790); the bench passes 2560 (64 MHz at 25 kHz: MAME's frames are 17.12 ms, `debug/gradius4-commlog2150`) | The Voodoo's pixel clock from its PLL registers (dacData) | `sim/board_tb`: buffer swaps in step with MAME over frames 7501-7503 | visible |
| CPU and Voodoo clocks all clk_sys | `hornet_board.sv` (PPC, SHARC and Voodoo `ce`) | the real ratios (32, 36, 50 MHz) are not modelled; each part runs as fast as its CPI allows | clock enables at the real ratios, once each part's throughput is known | unverified: frame work finishes within the frame in `sim/board_tb` | visible |
| Sync placed after the visible window | `rtl/board/hornet_video.sv` (`vid_hs`, `vid_vs`) | hsync 16-64 pixels after the 512-pixel window, vsync lines 3-6 after the 384-line window, on the 640-pixel line the board's `line_clocks` gives; not the Voodoo's hSync/vSync registers | sync from the Voodoo's hSync and vSync registers (MAME sets only its screen from them) | unverified on a monitor | visible |
| PPC instruction cache | `rtl/board/hornet_icache.sv` | MAME has none; 1 KB two-way of 8-word lines, not the 403GA's 2 KB. A store drops its line a clock or two late (registered), so a fetch from that line right after the store can hit the old words | the chip's geometry, and the drop in the store's clock | boot snapshots 140, 195, 625 and frames 7500, 2150 match in `board_tb`; a fetch right after a store to its line not checked | latent |
| SHARC on its own 48 MHz clock | `rtl/board/hornet_board.sv` (clk_dsp), `KonamiHornet.sv` | the chip runs at 36 MHz at about one instruction a clock; this core's SHARC needs about 2.5 clocks an instruction and closes only about 50 MHz, so it runs at 48 MHz on its own clock, its bus crossing to the board (posted writes, line reads for port B) | a SHARC at one clock an instruction | board_tb 2150 and 7500 keep step at +dspmhz=48 | latent |
| K056800 host side: a stand-in for the 68000 | `hornet_board.sv` `snd_*` | no 68000 yet: after SNDRES the status nibble counts at the 344.5 Hz timer, a sound interrupt is answered 4,096 clocks later with count + 1 and bit 7 toggled; command bytes are dropped | Phase 3 (fx68k, K056800, RF5C400) | boot from frame 625: MAME's handshake (0x05..0x0C, 0xF7, 0x8D) completes and attract starts; whether bit 7 toggles or stays set per command is unverified (one reply seen) | visible (no sound) |
| K033906 initEnable not passed on | `hornet_board.sv` K033906 register writes | vraster has no init-enable gate on fbiInit writes | a gate in the register bank | unverified | latent |
| CG board id 1 treated as absent | `hornet_board.sv` `cg_ok` | MAME indexes a second board's arrays with id 1 (konppc.cpp:131-150); one board here | a second board, or MAME's behaviour | the game writes id 0 in the traced windows | latent |
| sysreg port 3 constant 0xF0 | `KonamiHornet.sv` and `sim/board_tb` `in3` | JVS sense (bit 7, high: no JVS device), X76F041 EEPDO and the ADC bits are not modelled | the JVS host and the security EEPROM | MAME reads 0xF0 at frames 340 and 458 of the boot (`debug/gradius4-bootlog`); with Skip Post on or off the boot never selects the X76F041 to frame 1500 (`debug/gradius4-bootlog-post`) | latent |
| clutData taken while fbiInit1 holds video timing reset | `hornet_board.sv` clutData snoop | MAME ignores those writes (voodoo.cpp:2436) | snoop fbiInit1 | unverified | latent |
| PIT phase at a snapshot | `sim/board_tb/main.cpp` | MAME's PIT countdown is a scheduler timer, not a save item: the board starts a full period | none on the MAME side | unverified | tooling |
| PPC403 serial port and DMA controller absent; the line status reads 0x06 | `ppc403_core.sv` (external DCRs); `hornet_board.sv` `d_spu` | the boot sets up the port at frames 222, 340, 458 and polls SPLS, which MAME reads as 0x06 (`debug/gradius4-bootlog`); nothing is sent or received | Port ppc4xx_spu and ppc4xx_dma_exec (JVS for nbapbp) | reset trace 1M, windows 3000 and 7500; boot log | latent |
| vraster: perspective divide in fixed point | `rtl/raster/vraster_tri.svh` pixel pipeline q4-q9 | MAME computes s32(iters * (256.0 / iterw)) in doubles; here a 10-bit seed, one Newton step, a 24-bit reciprocal and S/T without their low 8 bits | a wider reciprocal and product (the full-width version matched the windows exactly) | frame 2150: 150 of 196,608 pixels differ (max 28 levels), 7500: 5 (max 4) | accepted (user: Voodoo rendering differences) |
| vraster: triangle edges in fixed point | `rtl/raster/vraster_tri.svh` edge_x20 | poly.h walks edges in float; here slopes with 20 fraction bits from an exact division | float, or exact rationals | windows 2150, 3000, 7500 match MAME's spans | latent |
| vraster: iterated R/G/B taken as 0 | `rtl/raster/vraster_tri.svh` pix_color | the game never writes them and their registers stay 0 (`debug/gradius4-vcensus-*`, captured states) | iterators like A's | census over attract and play | latent |
| vraster: no Z iteration, fog, stipple, alpha planes, LFB writes, NCC or palette textures, LOD selection | `rtl/raster` | the game uses none of them (docs/RASTER.md census) | MAME's paths | census over attract and play | latent |
| SHARC data memory 16K words | `rtl/board/hornet_board.sv` (`sharc2_core` DM_WORDS) | the ADSP-21062's block 1 is 32K words; addresses above 16K alias, for the board's M10K | 32K words (128 or 112 M10K) | `scripts/mame_sharc_dm_census.py`: 30,000 frames of attract and 15,000 with a game touch only 0x28000-0x2A7FF (`debug/gradius4-dmcensus-*`); simulation reports an access past 16K | latent |
| K037122 SRAM 24K words | `rtl/board/hornet_board.sv` (`g_ksram`) | the SRAM is 32K words; the fourth quarter (0x6000-0x7FFF) is not built: writes are dropped and reads return 0, for the board's M10K | 32K words (128 M10K, 96 now) | `scripts/mame_k037122_census.py`: 30,000 frames of attract and 15,000 with a game write that quarter only with zeros, and control register 0x34 takes only 0x00 and 0xC8 (bit 2 clear: palette at 0, tilemap at 0x2000-0x5FFF; `debug/gradius4-kscensus-*`) | latent |
| HDMI rotation in RGB565 | `rtl/mister/hornet_rotate.sv` (`pix`) | four pixels a 64-bit beat keep the rotator to a DDR3 command per four pixels on the Voodoo's port; the picture is 8:8:8 | 32 bpp beats of two pixels: twice the commands, or bursts and more line buffers | `sim/rotate_tb`; unverified on hardware | visible |

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
| M48T58 clock registers static | the commit adding `rtl/board/hornet_rtc.sv` | MAME's timekeeper counters, seeded from hps_io's RTC as the board leaves reset (`sim/rtc_tb`) |
