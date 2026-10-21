# openroad -exit flow/sta.tcl, with CORNER set (e.g. max_ss_100C_1v60)
# reports timing and writes the SDF

source [file dirname [info script]]/common.tcl

set corner $::env(CORNER)
lassign [split $corner _] rc process temp volt
set lib $sc/lib/sky130_fd_sc_hd__${process}_${temp}_${volt}.lib
set rules $pdk/libs.tech/openlane/rules.openrcx.$::env(PDK).$rc.calibre
if {![file exists $rules]} {
  set rules $pdk/libs.tech/openlane/rules.openrcx.$::env(PDK).$rc.spef_extractor
}

read_db $run/final/odb/$design.odb
read_liberty $lib
read_sdc [file dirname [info script]]/constraints.sdc
set_propagated_clock [all_clocks]

file mkdir $run/final/spef/$corner $run/final/sdf/$corner $run/reports
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $rules
write_spef $run/final/spef/$corner/${design}__$corner.spef
read_spef $run/final/spef/$corner/${design}__$corner.spef

set rpt $run/reports/sta_$corner.rpt
check_setup -verbose
report_checks -path_delay max -fields {slew cap input_pins} -digits 3 > $rpt
report_checks -path_delay min -fields {slew cap input_pins} -digits 3 >> $rpt
report_check_types -max_slew -max_capacitance -max_fanout -violators >> $rpt
puts "== $corner"
report_worst_slack -max -digits 3
report_worst_slack -min -digits 3
report_check_types -max_slew -max_capacitance -violators

write_sdf -divider . $run/final/sdf/$corner/${design}__$corner.sdf

if {[worst_slack -max] < 0 || [worst_slack -min] < 0} {
  puts "ERROR: $corner fails timing"
  exit 1
}
