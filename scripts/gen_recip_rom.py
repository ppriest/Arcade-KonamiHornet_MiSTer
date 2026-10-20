#!/usr/bin/env python3
"""Generates rtl/raster/vraster_recip.hex: the reciprocal seed ROM of vraster's perspective divide,
2^62 / m for a 32-bit mantissa m with its top bit set, indexed by m's 10 bits below the top (the
interval's midpoint), bits 30..17 of the 31-bit value kept. One Newton step follows in hardware."""
from pathlib import Path
RB = 10
vals = [((1 << 62) // ((((1 << (RB + 1)) | (i << 1) | 1) << (31 - RB - 1)))) >> 17 for i in range(1 << RB)]
Path(__file__).resolve().parent.parent.joinpath("rtl/raster/vraster_recip.hex").write_text(
    "
".join(f"{v:04X}" for v in vals) + "
")
