# 64 MHz: the provisional clk_sys (ROADMAP, Clocks)
create_clock -name clk -period 15.625 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports {reset din}] -to *
set_false_path -from * -to [get_ports dout]
