// SPDX-License-Identifier: GPL-3.0-or-later
// sim/voodoo_tb against vraster (rtl/raster), docs/RASTER.md.
//     scripts/run_verilator.sh vraster_tb +win=debug/gradius4-voodoo3000
#include "Vtb_vraster.h"
#include "Vtb_vraster___024root.h"
#define VTOP Vtb_vraster
#define TBNAME tb_vraster
#define MEMFIFO
#include "../voodoo_tb/main.cpp"
