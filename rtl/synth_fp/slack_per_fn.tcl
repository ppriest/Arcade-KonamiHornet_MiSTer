project_open fp
create_timing_netlist
read_sdc
update_timing_netlist
foreach m {f_add f_sub f_avg f_addsub f_mul f_fix f_float f_recips f_rsqrts f_comp f_minmax f_logb f_scalb f_clip} {
  set p [get_timing_paths -setup -npaths 1 -to [get_registers "m_${m}:u_${m}|r*"]]
  foreach_in_collection x $p { puts "$m [get_path_info $x -slack]" }
}
