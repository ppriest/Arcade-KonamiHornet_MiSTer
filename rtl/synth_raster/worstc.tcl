project_open synth_raster
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc
update_timing_netlist
foreach_in_collection x [get_timing_paths -setup -npaths 15 -nworst 1] {
  puts "[format %.3f [get_path_info $x -slack]] [get_node_info -name [get_path_info $x -from]] -> [get_node_info -name [get_path_info $x -to]]"
}
