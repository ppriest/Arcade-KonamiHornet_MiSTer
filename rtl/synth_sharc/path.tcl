project_open synth_sharc
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 1 -detail full_path -to [get_keepers *x_sX*] -file p1.txt
report_timing -setup -npaths 1 -detail full_path -to [get_keepers *rfp*] -file p2.txt
report_timing -setup -npaths 1 -detail full_path -to [get_keepers *pm_rtl*] -file p3.txt
