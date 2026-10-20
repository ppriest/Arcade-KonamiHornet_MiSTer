project_open synth_raster
create_timing_netlist
read_sdc
update_timing_netlist
set p [get_timing_paths -setup -npaths 20000 -nworst 1 -less_than_slack 0]
array set best {}
foreach_in_collection x $p {
  set f [get_node_info -name [get_path_info $x -from]]
  set t [get_node_info -name [get_path_info $x -to]]
  regsub {\|.*$} [regsub {^(altsyncram:|hornet_dpram:)} $f {}] {} fk
  regsub -all {\[[0-9]+\]|~DUPLICATE|\..*$|_rtl_0} $f {} fk
  regsub -all {\[[0-9]+\]|~DUPLICATE|\..*$|_rtl_0} $t {} tk
  regsub {\|.*} $fk {} fk; regsub {\|.*} $tk {} tk
  set k "$fk -> $tk"
  set s [get_path_info $x -slack]
  if {![info exists best($k)] || $s < $best($k)} { set best($k) $s }
}
foreach k [array names best] { puts "[format %.2f $best($k)] $k" }
