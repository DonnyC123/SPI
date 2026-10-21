# openroad -exit flow/pnr.tcl
# Floorplan, power grid, placement, clock tree, routing and fill

source $::env(FLOW_DIR)/common.tcl

read_lef $tlef
read_lef $cell_lef
# All three corners
define_corners ss tt ff
read_liberty -corner ss $sc/lib/sky130_fd_sc_hd__ss_100C_1v60.lib
read_liberty -corner tt $lib_tt
read_liberty -corner ff $sc/lib/sky130_fd_sc_hd__ff_n40C_1v95.lib
read_verilog $run/synth.v
link_design $design
read_sdc $::env(FLOW_DIR)/constraints.sdc
set_dont_use $pnr_dont_use

set_wire_rc -signal -layer met2
set_wire_rc -clock -layer met5

initialize_floorplan -utilization $::env(FP_CORE_UTIL) -aspect_ratio 1 \
  -core_space 5.52 -site unithd
# Make the routing tracks from the PDK. Read the layer, X/Y, offset, pitch
set fh [open $pdk/libs.tech/openlane/sky130_fd_sc_hd/tracks.info]
foreach {layer dir offset pitch} [read $fh] {
  set tracks($layer,$dir) [list $offset $pitch]
}
close $fh
foreach layer {li1 met1 met2 met3 met4 met5} {
  lassign $tracks($layer,X) x_offset x_pitch
  lassign $tracks($layer,Y) y_offset y_pitch
  make_tracks $layer -x_offset $x_offset -x_pitch $x_pitch -y_offset $y_offset -y_pitch $y_pitch
}

tapcell -distance 13 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1 \
  -endcap_master sky130_fd_sc_hd__decap_3

# Power grid
add_global_connection -net VPWR -pin_pattern {^VPWR$} -power
add_global_connection -net VPWR -pin_pattern {^VPB$}
add_global_connection -net VGND -pin_pattern {^VGND$} -ground
add_global_connection -net VGND -pin_pattern {^VNB$}
global_connect
set_voltage_domain -name CORE -power VPWR -ground VGND
define_pdn_grid -name stdcell -starts_with POWER -voltage_domain CORE -pins {met4 met5}
add_pdn_stripe -grid stdcell -layer met1 -width 0.48 -followpins
add_pdn_stripe -grid stdcell -layer met4 -width 1.6 -spacing 1.7 -pitch 50 -offset 10 -starts_with POWER
add_pdn_stripe -grid stdcell -layer met5 -width 1.6 -spacing 1.7 -pitch 50 -offset 10 -starts_with POWER
add_pdn_connect -grid stdcell -layers {met1 met4}
add_pdn_connect -grid stdcell -layers {met4 met5}
pdngen

# Placement
set density [expr {($::env(FP_CORE_UTIL) + 10) / 100.0}]
global_placement -skip_io -density $density
place_pins -hor_layers met3 -ver_layers met2
global_placement -density $density
repair_tie_fanout sky130_fd_sc_hd__conb_1/LO
repair_tie_fanout sky130_fd_sc_hd__conb_1/HI
estimate_parasitics -placement
repair_design -slew_margin 40 -cap_margin 20
detailed_placement
optimize_mirroring
check_placement

# Clock tree
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_16 \
  -buf_list {sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_2} \
  -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
detailed_placement
estimate_parasitics -placement
repair_timing -setup -setup_margin 0.05
repair_timing -hold -hold_margin 0.1
detailed_placement
check_placement

# Global route
set_routing_layers -signal met1-met5 -clock met1-met5
set_global_routing_layer_adjustment met1-met5 0.3
global_route -congestion_iterations 50
estimate_parasitics -global_routing
global_route -start_incremental
repair_design -slew_margin 40 -cap_margin 20
repair_timing -hold -hold_margin 0.05
detailed_placement
global_route -end_incremental
repair_antennas sky130_fd_sc_hd__diode_2 -iterations 3
check_placement

# Detailed route and fill
if {[catch {detailed_route -bottom_routing_layer met1 -top_routing_layer met5 \
              -output_drc $run/reports/drt.rpt -verbose 1} err]} {
  if {![string match "*DRT-0509*" $err]} {
    error $err
  }
  detailed_route -output_drc $run/reports/drt.rpt -verbose 1
}
check_antennas
filler_placement {sky130_fd_sc_hd__decap_* sky130_fd_sc_hd__fill_*}
global_connect
check_placement

file mkdir $run/final/def $run/final/nl $run/final/pnl $run/final/odb
write_db $run/final/odb/$design.odb
write_def $run/final/def/$design.def
write_verilog $run/final/nl/$design.nl.v
write_verilog -include_pwr_gnd $run/final/pnl/$design.pnl.v
report_design_area
