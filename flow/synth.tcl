# yosys -c flow/synth.tcl

source [file dirname [info script]]/common.tcl

yosys read_liberty -lib $lib_tt
yosys read_verilog {*}$::env(VERILOG_FILES)
yosys chparam -set NUM_DEVICES $::env(NUM_DEVICES) $design
yosys hierarchy -check -top $design
yosys rename -top $design
yosys synth -top $design -flatten
yosys check -assert

yosys dfflibmap -liberty $lib_tt
set abc_args {}
foreach cell $synth_dont_use {
  lappend abc_args -dont_use $cell
}
yosys abc -liberty $lib_tt {*}$abc_args

yosys setundef -zero
yosys hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
yosys splitnets
yosys opt_clean -purge
yosys insbuf -buf sky130_fd_sc_hd__buf_2 A X

yosys check -assert
yosys tee -o $run/synth_stat.rpt stat -liberty $lib_tt
yosys write_verilog -noattr -noexpr -nohex -nodec $run/synth.v
