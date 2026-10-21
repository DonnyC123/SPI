# magic -dnull -noconsole -rcfile <sky130A.magicrc> flow/magic.tcl
# DEF -> GDS, then check DRC and LVS

source $::env(FLOW_DIR)/common.tcl

drc off
crashbackups disable
locking disable

# DEF to GDS
gds noduplicates true
gds readonly true
gds read $cell_gds
lef read $cell_lef
lef read $tlef
def read $run/final/def/$design.def
load $design
select top cell
file mkdir $run/final/gds
gds nodatestamp yes
gds write $run/final/gds/$design.gds

quit -noprompt
