# Read the core's debug probes over JTAG (In-System Sources and Probes).
#
#   python scripts/read_issp.py [instance] [clear] [set N] [pulse N]
#
# SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 -- there are no
# *signaltap* Tcl commands -- so ISSP is what a headless workflow can drive.
#
# The probe bus layout is defined where the bus is BUILT (the issp instance in
# the top-level .sv), not here. Keep the field tables in step with it: a
# silently shifted field decodes as plausible nonsense rather than as an error.
#
# Counters typically SATURATE and count per-cycle events, so they pin almost
# immediately: `clear` first and read again for a rate.

# --- core-specific: edit for this core -------------------------------------
# One table per ISSP instance id, {name lo hi format}; format is dec, sdec
# (signed 16), hex or bit. Bit numbers index the probe bus as the RTL
# concatenates it. Add an entry to the `switch` further down for each table.
# By convention source bit 0 pulsed is the counter clear.
# KonamiHornet.sv's probe F (bring-up), LSB first
set fields_F {
    {frames           0  15 dec}
    {dl_kbytes       16  31 dec}
    {ppc_insns       32  47 dec}
    {dsp_insns       48  63 dec}
    {ppc_pc          64  95 hex}
    {dsp_pc          96 119 hex}
    {a_acks         120 127 dec}
    {b_acks         128 135 dec}
    {s_read         136 136 bit}
    {b_req          137 137 bit}
    {a_req          138 138 bit}
    {dsp_idle       139 139 bit}
    {d_ready        140 140 bit}
    {rom_dl         141 141 bit}
    {board_reset    142 142 bit}
    {pll_locked     143 143 bit}
}
# probe H: the last whole frame's counts, latched at vblank (clocks are clk_sys, 64 MHz)
set fields_H {
    {overruns         0  11 dec}
    {c_reqs          12  27 dec}
    {c_busy_clk      28  51 dec}
    {c_max_clk       52  63 dec}
    {s_bursts        64  75 dec}
    {s_max_clk       76  87 dec}
    {v_writes        88 107 dec}
    {v_wait_clk     108 131 dec}
    {ddr_wr_beats   132 151 dec}
    {ddr_rd_beats   152 171 dec}
    {mf_beats       172 187 dec}
    {dsp_idle_clk   188 211 dec}
    {b_busy_clk     212 235 dec}
    {a_busy_clk     236 259 dec}
    {swaps          260 267 dec}
    {v_displayed    268 269 dec}
    {v_base0        270 295 hex}
    {frame          296 303 dec}
}
# probe V: the Voodoo, the last whole frame (vraster's io_dbg live at 164-179)
set fields_V {
    {triangles        0  15 dec}
    {fills           16  27 dec}
    {tri_clk         28  51 dec}
    {busy_clk        52  75 dec}
    {fifo_full_clk   76  99 dec}
    {ring_clk       100 123 dec}
    {tex_fills      124 139 dec}
    {tex_hold_clk   140 163 dec}
    {frontbuf       164 165 dec}
    {swaps_pending  166 168 dec}
    {tex_filling    169 169 bit}
    {staging_empty  170 170 bit}
    {ring_used      171 171 bit}
    {fifo_full      172 172 bit}
    {fifo_empty     173 173 bit}
    {cmd_state      174 177 dec}
    {fill_go        178 178 bit}
    {tri_go         179 179 bit}
    {frame          180 187 dec}
    {ring_bad       188 203 dec}
}
# probe K: the DDR3 port's command, live
set fields_K {
    {r_out            0   9 dec}
    {t_on            10  10 bit}
    {tq_any          11  11 bit}
    {state           12  13 dec}
    {master          14  16 dec}
    {is_read         17  17 bit}
    {addr_beat       18  46 hex}
    {burstcnt        47  54 dec}
    {w_left          55  65 dec}
    {b_left          66  73 dec}
    {w_out           74  74 bit}
    {ddram_we        75  75 bit}
    {ddram_rd        76  76 bit}
    {ddram_busy      77  77 bit}
    {ddr_idle        78  78 bit}
    {RESET           79  79 bit}
    {status0         80  80 bit}
    {buttons1        81  81 bit}
    {rom_dl          82  82 bit}
    {nv_dl           83  83 bit}
    {ioctl_download  84  84 bit}
    {ioctl_index     85  92 dec}
    {pll_locked      93  93 bit}
    {board_reset     94  94 bit}
    {ldr_wr_wait     95  95 bit}
    {nv_seen         96  96 bit}
    {dl_seen_wr      97  97 bit}
    {dl0_seen        98  98 bit}
    {ldr_done        99  99 bit}
    {ldr_due        100 100 bit}
    {ldr_pending    101 101 bit}
    {ldr_active     102 102 bit}
    {ldr_addr_4k    103 117 hex}
    {rot_dropped    118 133 dec}
}
# probe D: the DDR3 port, the last whole frame (clk_sys clocks)
set fields_D {
    {busy_clk         0  23 dec}
    {idle_clk        24  47 dec}
    {room_wait_clk   48  71 dec}
    {rd_busy_clk     72  95 dec}
    {wr_clk          96 119 dec}
    {rd_cmds        120 139 dec}
    {wr_beats       140 159 dec}
    {rd_beats       160 179 dec}
    {rd_lat_sum     180 207 dec}
    {rd_lat_max     208 219 dec}
    {cmds_fbw       220 235 dec}
    {cmds_fbcw      236 251 dec}
    {cmds_fbaw      252 267 dec}
    {cmds_fbcr      268 283 dec}
    {cmds_fbar      284 299 dec}
    {cmds_tex       300 315 dec}
    {cmds_ring      316 331 dec}
    {cmds_portS     332 347 dec}
}
# ---------------------------------------------------------------------------

proc bits_to_int {s lo hi} {
    # read_probe_data returns the bus MSB-first, so index from the right.
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set do_clear [expr {[lsearch -exact $argv "clear"] >= 0}]
# `set N`   : write source byte N (decimal) and leave it
# `pulse N` : write N, then 0 -- for the edge-triggered controls
set set_val -1; set pulse_val -1
set i [lsearch -exact $argv "set"];   if {$i >= 0} { set set_val   [lindex $argv [expr {$i+1}]] }
set i [lsearch -exact $argv "pulse"]; if {$i >= 0} { set pulse_val [lindex $argv [expr {$i+1}]] }

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
puts "hardware: $hw"

set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} {
        set dev $d
    }
}
if {$dev eq ""} { puts "NO DEVICE FOUND"; exit 1 }
puts "device:   $dev"

# Query instance info BEFORE opening a session: with a session already active
# this fails with "There is already an active In-System Sources and Probes
# session started."
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
if {[llength $insts] == 0} {
    puts "NO ISSP INSTANCES -- is this an instrumented build?"
    exit 1
}
foreach i $insts { puts "instance: $i" }

# Take the first instance unless one is named on the command line (a single
# argument that is not a keyword or a keyword's value).
set want ""
set skip 0
foreach a $argv {
    if {$skip} { set skip 0; continue }
    if {$a eq "set" || $a eq "pulse"} { set skip 1; continue }
    if {$a ne "clear"} { set want $a }
}
set idx [lindex [lindex $insts 0] 0]
set inst_id [lindex [lindex $insts 0] 3]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0]; set inst_id $want }
    }
}

# The field table belongs to the INSTANCE. An unrecognised id stops rather
# than guesses.
switch -- $inst_id {
    F       { set fields $fields_F }
    H       { set fields $fields_H }
    V       { set fields $fields_V }
    D       { set fields $fields_D }
    K       { set fields $fields_K }
    default {
        puts "instance id '$inst_id' has no field table -- add one before reading it"
        exit 1
    }
}
puts "decoding instance $inst_id"

start_insystem_source_probe -device_name $dev -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
puts "raw ([string length $raw] bits): $raw"
puts ""

foreach f $fields {
    lassign $f name lo hi fmt
    set v [bits_to_int $raw $lo $hi]
    switch $fmt {
        sdec { if {$v >= 32768} { set v [expr {$v - 65536}] }; puts [format "  %-16s %d" $name $v] }
        hex  { puts [format "  %-16s 0x%08X" $name $v] }
        bit  { puts [format "  %-16s %s"     $name [expr {$v ? "yes" : "no"}]] }
        default { puts [format "  %-16s %d"  $name $v] }
    }
}

# write_source_data takes a BINARY STRING unless -value_in_hex is given; a
# decimal "8" is silently rejected. Every write goes through this, in hex.
proc write_src {idx v} { write_source_data -instance_index $idx -value [format %X $v] -value_in_hex }
if {$set_val >= 0}   { write_src $idx $set_val;   puts "source set to $set_val (reads back 0x[read_source_data -instance_index $idx -value_in_hex])" }
if {$pulse_val >= 0} { write_src $idx $pulse_val; write_src $idx 0; puts "source pulsed $pulse_val" }

if {$do_clear} {
    # Source bit 0 is the counter clear, by convention; the counters are
    # deliberately not reset by the core's own reset.
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
