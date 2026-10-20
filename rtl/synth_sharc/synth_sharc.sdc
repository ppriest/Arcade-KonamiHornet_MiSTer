create_clock -name clk -period 15.625 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports din] -to *
set_false_path -from * -to [get_ports dout]
# sharc2_alu's slow unit: two clocks from mc_* and w_trunc, four from avg_*
set_multicycle_path -setup 2 -from [get_registers {*u_alu|mc_x* *u_alu|mc_y* *u_alu|mc_op*}]
set_multicycle_path -hold 1  -from [get_registers {*u_alu|mc_x* *u_alu|mc_y* *u_alu|mc_op*}]
set_multicycle_path -setup 4 -from [get_registers {*u_alu|avg_x* *u_alu|avg_y*}]
set_multicycle_path -hold 3  -from [get_registers {*u_alu|avg_x* *u_alu|avg_y*}]
