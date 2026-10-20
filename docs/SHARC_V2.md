# SHARC v2: a pipelined core that fits

`rtl/cpu/sharc/sharc_core.sv` (v1) is MAME's interpreter transcribed: each instruction is one
combinational function over a copied 9.4k-bit state. It matches MAME's traces, but it synthesises
to 126,000 ALUTs with one compute unit (`rtl/synth_board`), 1.5x the whole device. v1 stays as
the golden model; v2 is checked against it in lockstep and against MAME's windows.

## Budgets

| | Target | Evidence |
|---|---|---|
| Area | 10-15k ALUTs, <= 8 DSP | device 83,820 ALUTs; Voodoo 46.8k, PPC 8.1k, video 8.0k, sys ~10k |
| Clock | 64 MHz (`clk_sys`), no enable | ROADMAP Clocks |
| Throughput | >= 33.5 M instructions/s at peak | 93% busy at 36 MHz (HARDWARE_NOTES, "SHARC usage") |
| Block RAM | PM 20,480 x 48 + DM 32,768 x 32 as now (2.03 Mbit) | board total 4.83 of 5.66 Mbit |

## Floating point: area is small, delay is not

`rtl/synth_fp` (each `sharc_fp_pkg` function in its own registered module, 5CSEBA6, 64 MHz
constraint, slow 100C model):

| Function | ALMs | Slack at 15.625 ns |
|---|---|---|
| f_avg | 679 | -36.4 |
| f_addsub | 493 | -23.7 |
| f_add | 406 | -25.9 |
| f_sub | 388 | -26.0 |
| f_mul | 301 (1 DSP) | -18.1 |
| f_fix | 225 | -18.0 |
| f_float | 174 | -15.1 |
| f_minmax | 54 | -10.8 |
| f_clip | 50 | -7.9 |
| f_recips, f_rsqrts, f_comp, f_scalb, f_logb | 11-45 each | -1.8 to +6.4 |

All of them together are about 2,950 ALMs. v1's size is its structure, not its arithmetic.
The delay is the problem: f_add is about 41 ns.

v2's units (`rtl/cpu/sharc2/`, bench `sim/sharc2fp_tb`: 5 M vectors against `sharc_fp_pkg`, 0
bad; timing `rtl/synth_fp` revision `fp2`, slack per stage from `paths.tcl`):

| Unit | ALMs | DSP | Slack stage 1 / stage 2 |
|---|---|---|---|
| `sharc_fadd` (near/far paths) | 511 | 0 | +0.44 / +2.47 |
| `sharc_fmul` (fast path; slow path +4.85, 4 stall clocks) | 376 | 2 | +6.24 / +3.29 |

Stage 2's spare time is where the forwarding mux goes; stage 1 must start from registers.

## Latency: what the game's code needs

`scripts/sharc_pipe_model.py` replays a MAME window's PC stream through an in-order, one-issue
pipeline. An instruction issues when the R registers and ASTAT it reads are ready. Result
latency is set per class (fixed, float, load), with a refill cost for taken jumps. IDLE,
DMA, alternate register sets and external waits are not modelled.

| Latency fixed/float/load, jump refill | CPI 7500 (play, 2M) | CPI 3000 (attract, 300k) |
|---|---|---|
| 1/1/1, 0 | 1.000 | 1.000 |
| **1/2/2, 2** | **1.535** | **1.337** |
| 1/3/2, 2 | 1.853 | 1.338 |
| 2/3/2, 2 | 1.940 | 1.752 |
| 1/3/3, 3 (1 delayed) | 2.071 | 1.570 |

The play code chains float results. At 1/2/2 with a 2-clock refill, CPI is 1.535, i.e. 41.7 MIPS at
64 MHz, 24% over the peak need; that margin covers DMA and external waits. At a float latency of 3
it is 34.6 MIPS: no margin. So the design needs a **2-stage float adder and multiplier at 64 MHz**
(bit-exact to `sharc_fp_pkg`, checked with `sim/sharcfp_tb`'s 9.2 M vectors) and a one-stage
fixed ALU and shifter with forwarding.

## Pipeline

```
F1  PM address (fetch PC, loop-end / branch redirect)
F2  PM data -> IR
D   decode; R and DAG reads; condition (ASTAT forwarded); DAG address and post-modify;
    interlock on the scoreboard
E1  fixed ALU, shifter, fixed multiply stage 1, float stage 1; DM/PM data access issued
E2  float stage 2, fixed multiply stage 2; load data returns; results and flags written
```

- Forwarding from E1 (fixed) and E2 (float, load) into D's operands and conditions.
- Scoreboard: per R register and ASTAT, the clock its value is ready.
- Taken jumps redirect at D: 2 bubbles, delayed forms fill them. DO UNTIL loop ends are predicted
  from the loop stack's top at F1 (no bubble); the counter decrement is at D.
- Two memory accesses (type 1 dual moves) take a second E1 clock. External accesses stall until
  `ext_ack`.
- One writer per state element: the register file, DAGs, stacks and system registers each have
  an explicit write-enable/data, with no copied state struct.
- Register file: R0-R15 plus the alternates, 32 bits (MAME's width), in flops. Up to 7 reads
  (multifunction 4 + two store data + shifter Rn) and up to 3 writes a clock. DAG I/M/L/B x 16
  plus alternates: flops or MLAB.
- PC stack (30), loop stacks (6), status stack (5): MLAB.
- Interrupts at D, between instructions, as v1 (`check_interrupts` order), with IDLE.
- DMA channels 6 and 7: v1's sequencer, sharing the DM port in the clocks the pipeline leaves
  free, with a stall after N clocks without a free slot.
- Boot DMA: v1's P_BOOT.

## Verification

1. `sim/sharc_tb` gets `+core=v2`: the same windows (3000, 7500, 150, 195, 216) compared with
   `scripts/compare_sharc_trace.py` in MAME's trace format.
2. Lockstep bench: v1 and v2 from the same state, compared at each retired instruction (PC, R,
   I/M, ASTAT, MODE1, stacks); the first difference stops the run.
3. `sim/board_tb` with v2: the snapshot frames against MAME, as now.
4. Standalone synthesis (`rtl/synth_sharc`) for area and Fmax before it goes into the board.

## Order

1. ~~Float adder and multiplier, 2 stages, bit-exact, timed.~~
2. Core: fetch, decode, the register file, fixed ALU and shifter, DM loads and stores, jumps,
   loops; lockstep against v1 on window 3000.
3. Float, multifunction, interrupts, the remaining forms; windows 7500, 150, 195, 216.
4. DMA and boot; board_tb.
5. Synthesis; then the first fit of the board.

## Status

- Correct: serial runs match MAME in PC and 56 registers on windows 3000 (300k instructions),
  7500 (2M), 195 and 216; pipelined runs replay every device access in order (`sim/sharc2_tb`).
- Clocks per instruction, window 7500 pipelined: 2.32 = 1.00 execute + 0.57 waiting for the
  MAME-paced DMA quantum + 0.50 bubbles (interlocks, taken jumps; the model's 0.53) + 0.24 slow
  accesses (`+pipe` breakdown). Without the DMA wait, 1.75.
- Standalone (`rtl/synth_sharc`), commit 91bf000: 33,984 ALMs, 29 MHz, X in one clock (29 levels).
- X rebuilt as micro-ops reading the registered state (commit 9dcad8f and after): the handler
  shares its clock with the pc shift, the loop end and the micro-ops that write other state; the
  rest take a clock each. D computes the DAG addresses and post-modify; the instruction's end comes
  from its class (decode) and D's address checks, not from its condition. Fit, commit ca0cf12:
  24,831 ALMs (core 18,155 own, ALU 5,955), 49.6 MHz (slow 100C). Window 7500 pipelined: 737,510
  clocks for 300k instructions (91bf000: 709,593).
- Remaining paths at ca0cf12: the PM RAM output (4 ns) through D's decode and hazard into the next
  fetch address; X's decode into the commit and the R file.
