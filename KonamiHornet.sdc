derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# sharc2_alu's slow unit: two clocks from mc_* and w_trunc, four from avg_*
set_multicycle_path -setup 2 -from [get_registers {*u_alu|mc_x* *u_alu|mc_y* *u_alu|mc_op*}]
set_multicycle_path -hold 1  -from [get_registers {*u_alu|mc_x* *u_alu|mc_y* *u_alu|mc_op*}]
set_multicycle_path -setup 4 -from [get_registers {*u_alu|avg_x* *u_alu|avg_y*}]
set_multicycle_path -hold 3  -from [get_registers {*u_alu|avg_x* *u_alu|avg_y*}]

# clk_dsp (counter 2, the SHARC) and clk_sys cross only through hornet_cdc's synchronisers and
# Gray-pointer FIFOs and the shared RAM's two ports
set_clock_groups -asynchronous -group [get_clocks {*pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -group [get_clocks {*pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]

# The DIP switches change only during a download
set_false_path -from [get_registers {*emu|dsw[*]}]

# ---------------------------------------------------------------------------
# SDRAM I/O timing, Arcade-KonamiGX_MiSTer's block (from Arcade-Seta_MiSTer), for the same
# controller on the same module: SDRAM_CLK is PLL counter 1, clk_sys (64 MHz, counter 0) at 180
# degrees. The numbers are that block's assumed MT48LC16M16A2 -7E values, not measured here.
# The first beat is captured two clk_sys edges after the memory's launch edge (KonamiGX.sdc).
# ---------------------------------------------------------------------------
set sdram_tAC   6.0
set sdram_tOH   2.7
set sdram_tDS   1.5
set sdram_tDH   0.8
set sdram_board 0.5
set sdram_board_min 0.1

create_generated_clock -name sdram_clk_pin -source [get_pins -compatibility_mode {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]

set_input_delay -clock sdram_clk_pin -max [expr {$sdram_tAC + $sdram_board}]     [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock sdram_clk_pin -min [expr {$sdram_tOH + $sdram_board_min}] [get_ports {SDRAM_DQ[*]}]

set sdram_dq_regs [get_registers {*sdram:u_sdram|dq_in[*]}]
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs
set_multicycle_path -hold  1 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs

set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -max [expr {$sdram_tDS + $sdram_board}]      $sdram_outs
set_output_delay -clock sdram_clk_pin -min [expr {-$sdram_tDH + $sdram_board_min}] $sdram_outs
