# Hornet rasteriser: a Voodoo 1 subset written for area

SpinalVoodoo does not fit beside the rest of the board: 26,489 ALMs for Gradius IV's subset
(HARDWARE_NOTES, Feasibility 5) against about 35k ALMs for the whole board beside `sys/`. It is
also unlicensed. This replaces it with a rasteriser written from MAME's Voodoo model
(`src/devices/video/voodoo*.cpp`, `voodoo_render.cpp`) for what Gradius IV uses, sized for area.

## What the game uses

Census over attract (frames 0-30000) and play (0-15000, coin at 4400), 39.3 M triangles
(`scripts/mame_voodoo_census.py`, `debug/gradius4-vcensus-{attract,play}/census.txt`):

- Triangles through the alternate register map, float registers only: vertices A/B/C, and start,
  dX, dY of A, S, T, W (63%) or of W alone (37%, flat colour from `color1`). No R/G/B or Z
  iteration, no fixed-point triangle registers.
- `fbzColorPath` (37 values): texture always on, sub-pixel adjust always on; the colour and
  alpha combine with most selectors in use (rgbselect texture or color1; alpha select iterated
  A, texture, color1; local select, mselect 0-4, sub clocal, add, reverse, invert on both
  paths). Implemented as MAME's general combine.
- `textureMode` (20 values): perspective on or off, point or bilinear for each of min and mag,
  clamp or wrap on S and T, formats RGB332, A8, ARGB8332, RGB565, ARGB1555, ARGB4444, texture
  combine (zero other, reverse, add local/alpha). `tLOD` (26 values): lodmin = lodmax in every
  value, levels 0-5, all aspect ratios, S-wider: one level a texture, no LOD computation.
- `alphaMode` (6 values): alpha test function 4 against reference 0; blend off, or source
  factors 0/1/2/4 and destination 0/1/4/5.
- `fbzMode` (7 values): clipping (always 512x384), chroma key on or off (colour 0), W-buffer,
  depth functions 3, 6, 7, depth bias (`zaColor` 0 or 0xFFFF), dither off/4x4/2x2, aux mask on
  or off, draw to the back buffer, y origin bottom.
- Commands: triangle, fast fill, swap buffer, nop; status reads. Texture memory writes
  (uploads, 7.9 M words); no LFB writes.
- Not used: fog (`fogMode` 0; its table and colour are written), stipple, alpha planes, NCC
  formats, palette, LOD dithering, trilinear, detail texture.

## Shape

Same ports as `CoreHornet` (the SHARC's register port, the Avalon masters to DDR3, the displayed
buffer out), so `hornet_board` does not change.

- Registers in block RAM where the pipeline reads them once a triangle; the float registers
  converted to fixed point one at a time as they are written.
- Edge walking from the vertices one span at a time; per-pixel parameters by adding dX, dY.
- One pixel pipeline, one pixel a clock when memory keeps up: W reciprocal for perspective (a
  table and one multiply, as MAME), texel address, a small texture cache, bilinear filter, colour
  combine, alpha test and blend, chroma key, depth test, dither, write.
- Fast fill as a write burst.
- Bit-exact to MAME's renderer: its arithmetic (`voodoo_render.cpp`) transcribed per stage.

## Budgets

| | Target | Evidence |
|---|---|---|
| Area | <= 12k ALMs | board ~35k beside sys/: PPC 5.9k, SHARC (redone) ~8-10k, video and glue ~9k |
| Clock | 64 MHz | ROADMAP Clocks |
| Fill | >= 0.6 pixels a clock with DDR3 | frame 2150: 418k triangle + 196k fast-fill pixels in a 1.06M-clock frame |
| Throughput in the board | frame 2150 in step with MAME at 64 MHz, DDR3 latency 24, 4 reads outstanding a port | `sim/board_tb +memlat=24 +memq=4`; falls a frame behind at 56 MHz (`+line=2240`), or with the 512-entry command FIFO at latency 16. Port contention is not modelled |

The SHARC's hand-built sequencer (docs/SHARC_V2.md) is the other half of the fit.

## Verification

1. `sim/voodoo_tb` with the new core: each window's frame buffer against MAME's
   (`end/fbram.bin`), pixel for pixel; the windows above, plus any the census shows are needed.
2. Per-stage checks against MAME's code where a frame differs (texel fetch, combine, blend).
3. Standalone synthesis for area and Fmax before it goes into the board.

## Order

1. ~~Census over a long run; freeze the subset.~~
2. ~~Register file, command decode, fast fill, swap: window 3000 (fast fill only) exact.~~
3. ~~Triangle setup, edge walk, W-buffer depth, flat colour: frame 7500's flat triangles.~~
4. Texture path (perspective, bilinear, formats, clamp/wrap, cache), combine, alpha test and
   blend, chroma key, dither: windows 2150 and 7500 exact.
5. ~~Synthesis; then into the board in place of CoreHornet.~~ 6,688 ALMs, 81 M10K, 64 DSP, 66.8 MHz
   at the slow -40C corner (`rtl/synth_raster`); `sim/board_tb` keeps step with MAME from both
   snapshots.
