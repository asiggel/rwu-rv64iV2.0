#===============================================================================
# 02c_rv64_gds.tcl
#
# Innovus: merged GDS of cc_chip_top for DRC and LVS. Sourced at the end of
# 02_rv64_floorplan_pnr.tcl (stage gds).
#
# Innovus only knows the abstracts (LEF) of the cells: write_stream writes
# the routing, vias and cell placements, and -merge copies the full layout
# of every cell from the X-FAB GDS files (standard cells, IO cells, SPRAM
# macros). The layer map translates the LEF layers to GDS layer/datatype.
#
#   cc_chip_top.gds          top cell cc_chip_top
#   cc_chip_top_gds.rpt      cells referenced in the layout but not found in
#                            GDS_FILES (must be empty, see
#                            scripts/innovus/innovus_pnr.sh)
#
# From $XFAB_PATHS: STREAM_MAP, GDS_FILES, GDS_UNIT.
# VERIFY-LAB: write_stream options in Innovus 26.1, the map file format the
# PDK provides (Innovus streamOut map), GDS_UNIT = database units per um of
# the X-FAB GDS (usually 1000).
#===============================================================================

set DESIGN_TOP cc_chip_top

foreach f [concat [list $STREAM_MAP] $GDS_FILES] {
  if {![file readable $f]} { error "AS-pnr: GDS input not readable: $f" }
}

write_stream ${DESIGN_TOP}.gds \
  -map_file       $STREAM_MAP \
  -merge          $GDS_FILES \
  -unit           $GDS_UNIT \
  -mode           ALL \
  -structure_name $DESIGN_TOP

# Cells of the design whose layout is in none of the merge files would
# leave empty boxes in the GDS: list every cell name used in the design and
# look for it in the merged files.
set fd [open ${DESIGN_TOP}_gds.rpt w]
set missing 0
set used [lsort -unique [get_db [get_db insts] .base_cell.name]]
set gdsText ""
foreach g $GDS_FILES {
  set gf [open $g r]
  fconfigure $gf -translation binary
  append gdsText [read $gf]
  close $gf
}
foreach c $used {
  if {[string first $c $gdsText] < 0} {
    puts $fd "missing in GDS_FILES: $c"
    incr missing
  }
}
puts $fd "cells used: [llength $used], missing: $missing"
close $fd
puts "AS-pnr: GDS written, [llength $used] cell types, $missing missing in GDS_FILES"
