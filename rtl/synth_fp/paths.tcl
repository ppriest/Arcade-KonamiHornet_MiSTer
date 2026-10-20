project_open fp2
create_timing_netlist
read_sdc
update_timing_netlist
foreach {n f t} {s1 "x* y* sub* trunc*" "*u_fadd|v_*" s2 "*u_fadd|v_*" "*u_fadd|r* *u_fadd|astat* *u_fadd|stky*" m1 "x* y*" "*u_fmul|v_*" m2 "*u_fmul|v_*" "*u_fmul|r* *u_fmul|astat* *u_fmul|stky*" ms "*u_fmul|q* *u_fmul|sc*" "*u_fmul|q* *u_fmul|slow_r* *u_fmul|sc*"} {
  set p [get_timing_paths -setup -npaths 1 -from [get_registers $f] -to [get_registers $t]]
  foreach_in_collection x $p { puts "$n slack [get_path_info $x -slack] from [get_node_info -name [get_path_info $x -from]] to [get_node_info -name [get_path_info $x -to]]" }
}
