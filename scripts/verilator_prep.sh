#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Per-bench preparation, called by run_verilator.sh with the bench name, from the repo root.
#
# voodoo_tb: SpinalVoodoo's generated Verilog $readmem's its ROM sidecars by bare file name,
# which the simulator resolves against its working directory (the repo root); copy them there.
# They are generated files and git-ignored at the root.
# board_tb: the same for CoreHornet, and the tb_board wrapper (scripts/board_wrapper.py).
set -euo pipefail
case "${1:-}" in
    voodoo_tb) cp -u rtl/voodoo/spinalvoodoo/CoreDe10.v_*.bin . ;;
    voodoop_tb) cp -u obj_voodoo/patched/CoreDe10.v_*.bin . ;;
    board_tb) cp -u rtl/voodoo/spinalvoodoo/CoreHornet.v_*.bin . && python scripts/board_wrapper.py ;;
esac
