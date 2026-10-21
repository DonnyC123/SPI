set period 10
create_clock -name clk -period $period [get_ports clk]
set_clock_transition 0.15 [get_clocks clk]
set_clock_uncertainty 0.25 [get_clocks clk]

set_input_delay 4 -clock [get_clocks clk] [all_inputs -no_clocks]
set_output_delay 4 -clock [get_clocks clk] [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
set_load 0.0334 [all_outputs]

set_timing_derate -early 0.95
set_timing_derate -late 1.05
set_max_transition 0.75 [current_design]
set_max_capacitance 0.2 [current_design]
set_max_fanout 16 [current_design]
