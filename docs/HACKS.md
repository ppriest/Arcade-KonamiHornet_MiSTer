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
| SHARC host-port DMA (IOP 0x04) absent | `sharc_core_ops.svh` `iop_write` | not used by the game | Port `external_dma_write` | profile: no host-port DMA in the traced windows | latent |
| SHARC delayed IOP write counted in instructions | `sharc_core_ops.svh` `iop_write` | MAME fires it from a timer at a timeslice boundary, so no count matches | nothing on the MAME side; a hardware reference would say what the chip does | the window benches take DMA-status reads and IRPTL's DMA bits from MAME's trace instead | tooling |
| SHARC BR8, BR0, SRCU and SSE mode bits ignored | `sharc_core_ops.svh` `sysreg_latency_effect` | fatal or view-switching in MAME; not set by the game | Implement bit-reverse, alternate MR, short-word sign extension | MODE1 only ever 0x1000/0x1480 in the profile | latent |
| PPC403 privileged-instruction checks absent | `rtl/cpu/ppc403/ppc403_core.sv` | the game runs in supervisor state | Program exception 0x40000 on PR = 1 | MSR.PR never set in the traced windows | latent |
| Voodoo output not bit-exact to MAME | `rtl/voodoo/spinalvoodoo` (SpinalVoodoo, patched) | Accepted by the user: remaining differences are not pursued. Small ones on iterated/textured triangles (1-2 LSB per channel), and isolated pixels of small triangles covered differently | Model MAME's colour iteration (start from vertex A's integer pixel, `voodoo_render.cpp:2291-2299`) and edge rule against SpinalVoodoo's, per differing pixel | `sim/voodoo_tb`: 4,613 of 196,608 back-buffer pixels differ at frame 2150, 5,381 (308 by 32 or more) at 7500; `docs/screenshots/voodoo/frame{2150,7500}_mame_core_diff.png` | visible |
| Video line length is an input | `rtl/board/hornet_board.sv` `line_clocks` | MAME picks a 15.75, 25 or 31.5 kHz line rate nearest its current period (voodoo.cpp:2746-2790); the bench passes 2560 (64 MHz at 25 kHz: MAME's frames are 17.12 ms, `debug/gradius4-commlog2150`) | The Voodoo's pixel clock from its PLL registers (dacData) | `sim/board_tb`: buffer swaps in step with MAME over frames 7501-7503 | visible |
| CPU and Voodoo clocks all clk_sys | `hornet_board.sv` (PPC, SHARC and Voodoo `ce`) | the real ratios (32, 36, 50 MHz) are not modelled; each part runs as fast as its CPI allows | clock enables at the real ratios, once each part's throughput is known | unverified: frame work finishes within the frame in `sim/board_tb` | visible |
| K056800 host side without the 68000 | `hornet_board.sv` `snd_to_host`, `host_to_snd` | the sound CPU's replies stay at the snapshot's values | Phase 3 (fx68k, K056800) | frames 7500-7504 run | visible (no sound) |
| M48T58 clock registers static | `hornet_board.sv` `nvram` | 8 KB RAM only; MAME's timekeeper counts time in the top registers | a timekeeper counter | unverified | latent |
| K033906 initEnable not passed on | `hornet_board.sv` K033906 register writes | SpinalVoodoo has no init-enable gate on fbiInit writes | a gate in the register bank | unverified | latent |
| CG board id 1 treated as absent | `hornet_board.sv` `cg_ok` | MAME indexes a second board's arrays with id 1 (konppc.cpp:131-150); one board here | a second board, or MAME's behaviour | the game writes id 0 in the traced windows | latent |
| sysreg port 3 constant 0x70 | `sim/board_tb` `in3` | JVS sense, X76F041 SDA and ADC bits are not modelled | the security EEPROM and JVS host (Phase 2) | not read in the frame-7500 PPC window | latent |
| Video memory reads answered at once in the bench | `sim/board_tb` ports C and S; `hornet_video.sv` | a line is built in the line before it, one character-RAM word and one frame-buffer word at a time; with SDRAM/DDR3 latency that is too slow | burst reads and a character cache sized from a measured worst line | all lines of frames 7501-7503 built in time with zero-latency ports | tooling |
| clutData taken while fbiInit1 holds video timing reset | `hornet_board.sv` clutData snoop | MAME ignores those writes (voodoo.cpp:2436) | snoop fbiInit1 | unverified | latent |
| PIT phase at a snapshot | `sim/board_tb/main.cpp` | MAME's PIT countdown is a scheduler timer, not a save item: the board starts a full period | none on the MAME side | unverified | tooling |
| PPC403 serial port and DMA controller absent; the line status reads 0x06 | `ppc403_core.sv` (external DCRs); `hornet_board.sv` `d_spu` | the boot sets up the port at frames 222, 340, 458 and polls SPLS, which MAME reads as 0x06 (`debug/gradius4-bootlog`); nothing is sent or received | Port ppc4xx_spu and ppc4xx_dma_exec (JVS for nbapbp) | reset trace 1M, windows 3000 and 7500; boot log | latent |

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
