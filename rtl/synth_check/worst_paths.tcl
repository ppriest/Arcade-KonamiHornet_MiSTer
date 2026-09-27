project_open synth_check
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 12 -detail summary -panel_name worst -file worst_summary.txt
report_timing -setup -npaths 1 -detail full_path -file worst_full.txt
project_close
