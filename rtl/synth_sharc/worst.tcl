project_open synth_sharc
create_timing_netlist
read_sdc
update_timing_netlist
set p [get_timing_paths -setup -npaths 200 -nworst 1]
set seen {}
foreach_in_collection x $p {
  set f [get_node_info -name [get_path_info $x -from]]
  set t [get_node_info -name [get_path_info $x -to]]
  regsub -all {\[[0-9]+\]} $f {[]} fk; regsub -all {\[[0-9]+\]} $t {[]} tk
  set k "$fk -> $tk"
  if {[lsearch $seen $k] < 0} { lappend seen $k; puts "[format %.2f [get_path_info $x -slack]] levels=[get_path_info $x -num_logic_levels] $k" }
}
