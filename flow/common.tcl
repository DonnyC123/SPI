# Paths shared by every flow script, from PDK_ROOT, PDK and RUN_DIR

set design  spi_top
set pdk     $::env(PDK_ROOT)/$::env(PDK)
set sc      $pdk/libs.ref/sky130_fd_sc_hd
set run     $::env(RUN_DIR)

set tlef    $sc/techlef/sky130_fd_sc_hd__nom.tlef
set cell_lef $sc/lef/sky130_fd_sc_hd.lef
set cell_gds $sc/gds/sky130_fd_sc_hd.gds
set cell_spice $sc/spice/sky130_fd_sc_hd.spice
set lib_tt  $sc/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

proc read_cells {f} {
  if {![file exists $f]} {
    error "missing cell list $f"
  }
  set fh [open $f]
  set cells {}
  foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line ne "" && ![string match "#*" $line]} {
      lappend cells $line
    }
  }
  close $fh
  return $cells
}

# drc_exclude: broken cells, never used. no_synth: CTS/fill/antenna cells, kept out of synthesis only
set cell_lists     $pdk/libs.tech/openlane/sky130_fd_sc_hd
set pnr_dont_use   [read_cells $cell_lists/drc_exclude.cells]
set synth_dont_use [lsort -unique [concat $pnr_dont_use [read_cells $cell_lists/no_synth.cells]]]

file mkdir $run $run/reports
