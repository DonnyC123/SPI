# magic -dnull -noconsole -rcfile <sky130A.magicrc> flow/magic_check.tcl
# DRC and LVS extraction on the written GDS

source $::env(FLOW_DIR)/common.tcl

drc off
crashbackups disable
locking disable

gds read $run/final/gds/$design.gds
load $design
select top cell

drc euclidean on
drc style drc(full)
drc check
drc catchup
set fh [open $run/reports/drc.rpt w]
set count 0
foreach {why boxes} [drc listall why] {
  puts $fh "$why"
  foreach box $boxes {
    puts $fh "  $box"
    incr count
  }
}
close $fh
puts "DRC errors: $count"
if {$count > 0} {
  exit 1
}

extract do local
extract no capacitance
extract no coupling
extract no resistance
extract no adjust
extract unique
extract all
ext2spice lvs
ext2spice -o $run/final/$design.layout.spice
file delete {*}[glob -nocomplain *.ext]

quit -noprompt
