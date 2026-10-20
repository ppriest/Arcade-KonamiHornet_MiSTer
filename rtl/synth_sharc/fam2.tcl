project_open synth_sharc
create_timing_netlist
read_sdc
update_timing_netlist
set p [get_timing_paths -setup -npaths 30000 -nworst 1 -less_than_slack 0]
array set best {}
array set lv {}
foreach_in_collection x $p {
  set f [get_node_info -name [get_path_info $x -from]]
  set t [get_node_info -name [get_path_info $x -to]]
  foreach v {f t} {
    set n [set $v]
    regsub {^.*sharc2_core:dsp\|} $n {} n
    regsub -all {\[[0-9]+\]|~DUPLICATE|_rtl_0|\.[a-z_0-9]+} $n {} n
    regsub {\|.*$} $n {} n
    set $v $n
  }
  set k "$f -> $t"
  set s [get_path_info $x -slack]
  if {![info exists best($k)] || $s < $best($k)} { set best($k) $s; set lv($k) [get_path_info $x -num_logic_levels] }
}
foreach k [array names best] { puts "[format %.2f $best($k)] L$lv($k) $k" }
