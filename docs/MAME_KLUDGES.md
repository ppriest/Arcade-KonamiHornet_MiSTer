# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
RTL reproduces MAME's guesses on purpose. This file lists each one that touches an in-scope set:
where it is in MAME, what the core does, and what would settle the real behaviour.

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `E:/mame/src/devices/cpu/...` at `mame0289-661-ga2d0f76268e` unless
named; the reference traces come from the MAME 0.289 binary.

**Core column:** *copies* MAME; *differs* (and why); *n/a*; *not checked*.

## PPC403GA

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| PVR reads as the model enum | `ppcdrc.cpp:4246-4247`: `mfspr PVR` returns `m_flavor`, 0x00200000 for the 403GA | copies, `ppc403_core.sv` mfspr | a 403GA's PVR |
| A timebase half write zeroes the other half | `ppccom.cpp:2224-2229` | copies | 403GA manual |
| PIT reads back the written value | `ppccom.cpp` mfspr default: no countdown is kept | copies | 403GA manual |
| The PIT runs only while TCR.PIE is set | `ppccom.cpp:2982-3000`: the timer is armed only with PIE | copies | 403GA manual |
| Every interrupt is gated by MSR.EE | `ppcdrc.cpp:805-811`: no separate critical-interrupt enable | copies | 403GA manual |
| lmw does not load rA, except r31 | `ppcdrc.cpp:2937` | copies | — |
| dcbz clears 32 bytes | `ppccom.cpp:715`: `m_cache_line_size = 32` for every model; the 403GA's line is 16 bytes by IBM's documentation (not checked here) | copies | 403GA manual |
| Cache instructions are no-ops; dcread/icread write 0 | `ppcdrc.cpp:4372-4383` | copies | — |
| stwcx. succeeds on the reservation flag alone | `ppcdrc.cpp:1240-1250`: no address compare | copies | — |
| Divide by zero and 0x80000000 / -1 give 0 | `ppcdrc.cpp:3549-3566` | copies | — |
| Alignment exceptions write the OEA DAR (SPR 19), not DEAR | `ppcdrc.cpp:984-987` | copies | — |

## SHARC (compute.hxx, as MAME's host-float code computes it)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| The multiplier does not flush denormals | `compute.hxx:435-455`: `FMUL` multiplies the host floats as they are; the ALU flushes (`FADD`, `compute.hxx:152-153`) | copies, `sharc_fp_pkg::f_mul` | 2106x manual: the chip flushes denormals to zero |
| 32-bit rounding only | host single-precision arithmetic; MODE1 RND32 and 40-bit data are ignored | copies | — (the game runs RND32 off; not measured whether it relies on 40-bit results) |
| SCALB adds the scale in a C `int` | `compute.hxx:409-410`: `exponent += int32_t(REG(ry))` wraps, so -2^31 gives infinity | copies, `sharc_fp_pkg::scalb` | — |
| SCALB of zero makes a number | `compute.hxx:404-428` works on the raw fields: 0 scaled by n >= 1 gives 2^(n-127) | copies | — |
| FIX out of range gives 0x80000000 | `int32_t(nearbyintf(f))` on x86: the conversion's "integer indefinite" | copies, `sharc_fp_pkg::f2i` | — |
| FIX truncation differs by form | single form `floorf` (`compute.hxx:1065-1068`), multifunction form a C cast toward zero (`compute.hxx:1594-1597`) | copies | — |
| Dual add/subtract of two infinities converts an integer | `compute.hxx:386, 391` assign the integer pattern to the float member | copies, `sharc_fp_pkg::f_addsub` | — |
| FLOAT BY sets AN differently by form | single form from the sign bit, multifunction form `f < 0` (`compute.hxx:1130` against `1569`) | copies | — |

Verified: `sim/sharcfp_tb` compares `sharc_fp_pkg` with these functions of `compute.hxx` run on
the host: 9,200,000 vectors over seeds 1 and 7, 23 operations, result and flags, 0 mismatches.

## Board (hornet.cpp, konppc.cpp)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| The SHARC looks for interrupts only at a timeslice start and after RTI or an IMASK write | `sharc.cpp` execute_run | differs: `hornet_board.sv` ties `irq_check_en` high, a check before every instruction | 2106x manual (interrupts are sampled every cycle) |
| konppc asserts SHARC IRQ0/1 and never clears them; each assert sets the pending bit | `konppc.cpp:176-180`, `sharc.cpp:1084-1097` | copies: `sharc_core` `irq_assert` | the CG board schematic |

## K037122 (`E:/mame/src/mame/konami/k037122.cpp`)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| The 128x128 map takes incyx without the << 4 the other increments get | `k037122.cpp:170` | copies, `hornet_video.sv` `incyx`; not exercised by frames 7500-7504 (unrotated HUD) | a rotated 128x128 map on hardware |
| The whole frame is drawn with the registers at its end | `hornet.cpp` screen_update, once a frame | differs: `hornet_video.sv` uses the registers when each line is built | a mid-frame register change on hardware |

## Voodoo 1 (`E:/mame/src/devices/video/voodoo_render.cpp`; SpinalVoodoo, patched)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| CLUT entry 32 of 0 with entry 31 non-zero reads as white | `voodoo.cpp:862-863` (for Midway games) | copies, `hornet_video.sv` `clut_at` | � |
| 2x2 dither matrix 8 10 / 11 9 | `voodoo_render.cpp:45-51`, chosen so that iteagle's (Voodoo 3) memory tests pass | copies: `rtl/voodoo/patches/0002-dither-2x2-mame.patch` replaces SpinalVoodoo's 86Box tables (matrix 2 10 / 14 6). The 4x4 tables agree. Drawn-buffer pixels differing from MAME: 10,530 to 4,613 (window 2150), 21,118 to 5,381 (7500) | a Voodoo 1 frame buffer drawn with 2x2 dither |
