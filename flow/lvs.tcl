# netgen -batch source flow/lvs.tcl
# Layout extracted from the GDS vs the powered netlist from OpenROAD

source $::env(FLOW_DIR)/common.tcl

set layout [readnet spice $run/final/$design.layout.spice]
set schematic [readnet spice $cell_spice]
readnet verilog $run/final/pnl/$design.pnl.v $schematic
lvs "$layout $design" "$schematic $design" $pdk/libs.tech/netgen/$::env(PDK)_setup.tcl $run/reports/lvs.rpt

# Only a clean match passes
set fh [open $run/reports/lvs.rpt]
set rpt [read $fh]
close $fh
if {![regexp {Final result: Circuits match (uniquely|correctly)\.} $rpt]} {
  puts "ERROR: LVS failed, see $run/reports/lvs.rpt"
  exit 1
}
quit
