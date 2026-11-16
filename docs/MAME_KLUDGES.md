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
| The multiplier does not flush denormals | `compute.hxx:435-455`: `FMUL` multiplies the host floats as they are; the ALU flushes (`FADD`, `compute.hxx:152-153`) | copies, `sharc_fp_pkg::f_mul` (MAME_RND 1); flushes at 0 ("SHARC at MAME_RND 0" below) | 2106x manual: the chip flushes denormals to zero |
| 32-bit rounding only | host single-precision arithmetic; MODE1 RND32 and 40-bit data are ignored | copies, at either MAME_RND | — (the game runs RND32 off; not measured whether it relies on 40-bit results) |
| SCALB adds the scale in a C `int` | `compute.hxx:409-410`: `exponent += int32_t(REG(ry))` wraps, so -2^31 gives infinity | copies, `sharc_fp_pkg::scalb` (MAME_RND 1); exact at 0, in SCALB, FIX BY and FLOAT BY | — |
| SCALB of zero makes a number | `compute.hxx:404-428` works on the raw fields: 0 scaled by n >= 1 gives 2^(n-127) | copies (MAME_RND 1); ±0 at 0 | — |
| FIX out of range gives 0x80000000 | `int32_t(nearbyintf(f))` on x86: the conversion's "integer indefinite" | copies, `sharc_fp_pkg::f2i` (MAME_RND 1); B-37's results and flags at 0 | — |
| FIX truncation differs by form | single form `floorf` (`compute.hxx:1065-1068`), multifunction form a C cast toward zero (`compute.hxx:1594-1597`) | copies (MAME_RND 1); `floorf` in both at 0 | — |
| Dual add/subtract of two infinities converts an integer | `compute.hxx:386, 391` assign the integer pattern to the float member | copies, `sharc_fp_pkg::f_addsub` (MAME_RND 1); an infinity and a NaN at 0 | — |
| FLOAT BY sets AN differently by form | single form from the sign bit, multifunction form `f < 0` (`compute.hxx:1130` against `1569`) | copies (MAME_RND 1); the sign bit in both at 0 | — |

Verified: `sim/sharcfp_tb` compares `sharc_fp_pkg` with these functions of `compute.hxx` run on
the host: 9,200,000 vectors over seeds 1 and 7, 23 operations, result and flags, 0 mismatches.

### SHARC at MAME_RND 0: the manual

`sharc_core` and `sharc2_core` take `MAME_RND`, passed through `sharc2_alu` to `sharc_fadd` and
`sharc_fmul`. 0, the default everywhere and what the board builds (`hornet_board`'s
`SHARC_MAME_RND`), is the manual: the
ADSP-2106x SHARC User's Manual, rev 2.1 (82-000795-03): every float operation as its Appendix B
entry says, results and flags, through `sharc_fp_pkg`'s `man_*` functions (v1, and v2's slow unit)
and the units' own paths. Pages are the printed ones. 1 is MAME's arithmetic above, bit for bit; the
benches that compare with MAME set it.

General rules, every float operation:

- Denormal operands are flushed to zero in every unit and do not underflow (p. 2-3, 2-16).
- MODE1.TRUNC rounds toward zero, else to nearest (p. 2-6, 2-7, 2-15). RND32 set: results at 24
  bits. Underflow and overflow are of the post-rounded result, the exponent unbounded (p. 2-8,
  2-16, 2-17).
- An underflow is a signed zero with AZ and AUS (ALU) or MU and MUS (multiplier); an overflow is
  ±infinity, or ±NORM.MAX under TRUNC, with AV and AVS or MV and MVS (B-24, B-25, B-26, B-27, B-28,
  B-34, B-53; p. 2-8, 2-16, 2-17). The entries' "AU" is AUS here: this ASTAT has no AU, and the
  ALU's underflow flags are AZ and AUS (p. 2-8).
- A NaN input gives all 1s with AI and AIS, or MI and MIS; so does an invalid operation:
  opposite-signed infinities added, like-signed subtracted, infinity times zero (p. 2-9, 2-17).

Where MAME and the manual differ, operation by operation:

| Operation | MAME | MAME_RND 0 (the manual) |
|---|---|---|
| FADD, FSUB, ABS of a sum or difference | to nearest whatever MODE1 holds (`compute.hxx:156-172`) | rounded by TRUNC and RND32 (B-24 to B-27) |
| FAVG | the sum rounded, then halved, so a sum past NORM.MAX overflows | (Fx + Fy)/2 rounded once; its flags are of the post-rounded result, so it overflows only on an infinite operand (B-28) |
| Dual add/subtract | two infinities give an integer converted to float (`compute.hxx:386, 391`) | AI when both inputs are infinite (B-78); the values are not given: the valid one's infinity and a NaN (IEEE) |
| FMUL | operands and results not flushed, gradual underflow (`compute.hxx:435-455`) | operands flushed; rounded by TRUNC and RND32; MU and MUS on a post-rounded underflow, the result ±0 (B-53; p. 2-16); MV and MVS on a post-rounded overflow (p. 2-17); `sharc_fmul` has no slow path (`busy` 0) |
| FIX, FIX BY | out of range 0x80000000; TRUNC: floorf, multifunction a C cast toward zero; BY through SCALB, so a scaled value below 2^-126 is 0; flags AZ, AN, AUS on a denormal operand | Ry added to the exponent before the conversion, exactly; TRUNC toward minus infinity, else to nearest, in both forms (B-37, table B.7, p. B-81). ±Infinity or an exponent plus scale above 157: AV; under ALUSAT 0x7FFF FFFF or 0x8000 0000, else all 1s with AI and AIS; a NaN all 1s with AI (B-37; ALUSAT, p. 2-6). AUS when the scaled value is below 2^-126 |
| FLOAT, FLOAT BY | to nearest at 24 bits; overflow infinity without AV; AN by form (`compute.hxx:1130` against `1569`) | exact at 40 bits (B-38): truncated at 24 bits under RND32, which is what an RND32 operation reads of it (p. 2-7, 2-15), else rounded to nearest; after BY, overflow ±infinity or ±NORM.MAX by TRUNC with AV and AVS, underflow ±0 with AZ and AUS (B-38). One rule for both forms. The 8 bits a 40-bit register keeps: `HACKS.md` |
| SCALB | the raw fields: a denormal operand scaled, zero becomes a number, the scale wraps in a C `int`; no AV | operand flushed; exact; overflow ±infinity or ±NORM.MAX with AV and AVS; a result below 2^-126 ±0 with AZ and AUS (B-34) |
| LOGB | a denormal operand gives -127; no saturation | operand flushed, so a denormal gives -infinity with AV; under ALUSAT ±infinity give 0x7FFF FFFF and zero 0x8000 0000 (B-36; p. 2-6) |
| RSQRTS | ±0 gives a number with AV; +infinity a number; AI on -0 | ±0 gives ±infinity with AV; +infinity +0 with AZ; AI only for a NaN or a negative nonzero input (B-40) |
| RECIPS | a denormal operand gives a number; no AN for -0 | operand flushed, so ±infinity with AV; AN for a negative input, -0 included (B-39; B-40 counts -0 as negative) |
| MIN, MAX | denormals compared as values; MIN(+0, -0) is +0 | denormals flushed; MIN(+0, -0) is -0, MAX(+0, -0) +0 (B-42, B-43) |
| COMP | denormals compared as values | operands flushed (p. 2-3) |

ABS, PASS, NEG, COPYSIGN and CLIP are MAME's at both settings: their entries (B-30, B-31, B-32,
B-41, B-44) match `f_abs`, `f_pass`, `f_neg`, `f_copysign` and `f_clip`. The ALU's add and subtract
already flushed as p. 2-3 asks, in MAME and so at both settings: operands through `flush`, a
denormal result a signed zero with AZ and AUS (`alu_fin`); their tiny results come only from
cancellation, which is exact (`sharc_fadd`'s near path).

RND32 = 0. The chip's results are then 40 bits, the exact value rounded at 32 significant bits;
40-bit registers and data paths are not built, so these 32-bit registers hold MAME's
approximation: rounded to nearest at 24 bits, under TRUNC too. Truncating at 24 bits would be off
by up to one 24-bit unit in the last place, always toward zero, 256 times the chip's own
truncation and accumulating along a chain of operations; rounding to nearest is within half a unit
of the chip's value and does not drift. What TRUNC does keep is that a truncated 40-bit result
never crosses a boundary, and the 40-bit rounding moves a value by less than 2^-32: so at RND32 = 0
underflow and overflow are decided on the exact value, a 24-bit round-up across 2^128 gives
NORM.MAX without AV, and nothing is rounded up to 2^-126. FLOAT follows the same rule (exact at 40
bits, so rounded to nearest at 24). The game runs MODE1 0x1000 / 0x1480 (`HACKS.md`, the BR8 row):
TRUNC and RND32 clear.

The manual does not say, and the core chooses:

- **An infinite operand** (not an invalid operation): the entries give results only for a rounded
  overflow. Kept from MAME: the ALU and SCALB give NORM.MAX under TRUNC, else infinity, with AV and
  AVS; the multiplier gives infinity with MV and MVS.
- **The dual add/subtract of two infinities** (B-78): AI is stated, the values are not. The core
  gives the valid operation's infinity (then as above) and a NaN for the other.
- **The multiplier's result values** on overflow and on a NaN: B-53 and p. 2-15 to 2-17 give only
  the flags. The core uses the ALU entries' values: ±infinity, or ±NORM.MAX under TRUNC; all 1s.
- **SCALB of zero** (B-34 does not address a zero input): ±0 with AZ.
- **-0 and AN**: the entries say "negative". B-40 sets AN for a -0 input, so the core counts -0 as
  negative everywhere (the sign bit); a NaN result does not set AN.
- **The sticky flag of a fixed-point AV** (FIX, LOGB, RECIPS and RSQRTS of zero): the entries
  give only ASTAT.AV, and p. 2-8 ties AVS to floating-point overflow and AOS to fixed-point. The
  core sets neither, as MAME.
- **RECIPS and RSQRTS seed mantissas**: the entries give the seeds' accuracy, not their tables.
  MAME's tables.

MODE1.RND32 = 0 results at 40 bits are not built at either setting (the row "32-bit rounding
only").

Verified: `sim/sharcman_tb` checks the `man_*` functions and both units at MAME_RND 0 against a
reference written from the entries above, rounding the exact long-double result by its own code:
210,000,000 vectors over seeds 1 and 7, 21 operations, TRUNC and RND32 each set in half of them
and ALUSAT in a quarter (30,000,000 through the units), result and flags, 0 mismatches. `sim/sharclock_tb`
runs v1 against v2 (serial at every instruction, pipelined at the end) on generated programs
that toggle TRUNC, RND32 and ALUSAT: at MAME_RND 0, 3,000 programs and 10,251,871 instructions
(ONE_FADD 1 and 0), 0 failed; v1 at 1 against v2 at 0 fails every program. 22 planted faults,
one edit each for every rule above, are all caught: `sharcman_tb` those in a function or unit,
the lockstep those in the cores' wiring (RND32 and ALUSAT to the units, v2's dual add/subtract); a
fault in a `man_*` function that v1 and v2 share is invisible to the lockstep. At MAME_RND 1,
`sim/sharclock_tb +hash` prints the same hash of every retired instruction (clock, PC, 56
registers, all three cores) as the bench built on the RTL before the parameter, over 800
programs, and `sim/sharcfp_tb` and `sim/sharc2fp_tb` print what they did.

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

## Sound board (MiSTer_ArcadeSoundServer's src/hornet, on the HPS)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| RF5C400 register writes take effect per 20 ms block | `emu/sound.h:126`: streams render at 50 Hz, and `rf5c400_w` does not update its stream first, so a write applies to the whole block it falls in | copies, `hornet/board.cpp` `run_until` | a recording of the board |
| The sound timer restarts with the 68000's reset | `hornet.cpp:1405` `set_periodic_int`: the device's timer is re-armed by its reset, which releasing SNDRES runs; measured: MAME's timer writes sit 16 us into periods counted from the release (`debug/gradius4-sndlog0-5800`) | copies, `restart_timer` | the board's timer circuit (16.9344 MHz / 384 / 128, free-running on the PCB?) |
| RF5C400 envelopes, effects and filter | `rf5c400.cpp:66-107` "experimental" envelope tables; effects sends and the cutoff are not applied | copies (effect outputs unused, as `hornet.cpp` routes only outputs 0-1) | the chip's documentation |
