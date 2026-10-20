#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SHARC v2 against MAME: serial runs of the windows compared in PC and 56 registers
# (scripts/compare_sharc_trace.py), then a pipelined run of 7500, whose device accesses must
# all replay.
#
#     scripts/sharc2_regress.sh [--full]      # --full: window 7500 for 2M instructions, not 300k
set -u
cd "$(dirname "$0")/.."
N7500=300000
[ "${1:-}" = "--full" ] && N7500=2000000
fail=0
run() {   # window, instructions
    local w=debug/gradius4-sharc$1
    rm -f $w/rtl2.tr
    if ! scripts/run_verilator.sh sharc2_tb +win=$w +n=$2 > $w/regress.log 2>&1 && grep -q "%Error\|error:" $w/regress.log; then
        echo "$1: build failed"; grep -m5 "%Error\|error:" $w/regress.log; exit 1
    fi
    local r
    r=$(python scripts/compare_sharc_trace.py $w --rtl rtl2.tr | tail -1)
    echo "$1 serial: $r"
    case "$r" in MATCH*) ;; *) fail=1; python scripts/compare_sharc_trace.py $w --rtl rtl2.tr | head -20 ;; esac
}
run 3000 300000
run 195 170000
run 216 160000
run 7500 $N7500
w=debug/gradius4-sharc7500
scripts/run_verilator.sh sharc2_tb +win=$w +n=$N7500 +pipe > $w/regress_pipe.log 2>&1
grep -E "^clocks|instructions," $w/regress_pipe.log | sed 's/^/7500 pipelined: /'
grep -q "instructions," $w/regress_pipe.log || fail=1
exit $fail
