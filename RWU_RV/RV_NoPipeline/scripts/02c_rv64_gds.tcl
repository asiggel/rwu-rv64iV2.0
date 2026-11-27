#===============================================================================
# 02c_rv64_gds.tcl
#
# Innovus: merged GDS of cc_chip_top for DRC and LVS. Sourced at the end of
# 02d_rv64_postroute.tcl (stage gds).
#
# Innovus only knows the abstracts (LEF) of the cells: write_stream writes
# the routing, vias and cell placements, and -merge copies the full layout
# of every cell from the X-FAB GDS files (standard cells, IO cells, SPRAM
# macros). The layer map translates the LEF layers to GDS layer/datatype.
#
#   cc_chip_top.gds          top cell cc_chip_top, with pad labels for LVS
#   cc_chip_top_labels.txt   the labels: name x y
#   cc_chip_top_gds.rpt      cells referenced in the layout but not found in
#                            GDS_FILES (must be empty, see
#                            scripts/innovus/innovus_pnr.sh)
#
# From $XFAB_PATHS: STREAM_MAP, GDS_FILES, GDS_UNIT, LABEL_LAYER, PAD_PIN.
# VERIFY-LAB: write_stream options in Innovus 26.1, the map file format the
# PDK provides (Innovus streamOut map), GDS_UNIT = database units per um of
# the X-FAB GDS (usually 1000).
#===============================================================================

set DESIGN_TOP cc_chip_top

foreach f [concat [list $STREAM_MAP] $GDS_FILES] {
  if {![file readable $f]} { error "AS-pnr: GDS input not readable: $f" }
}

# ------------------------------------------------------------------------
# Pad labels: LVS matches the chip ports and supplies by text labels in the
# layout. One label per pad, at the pad centre on LABEL_LAYER: the port name
# for signal pads (net on the PAD pin), VDD/GND/VDDO/GNDO for supply pads.
# Also written to cc_chip_top_labels.txt.
# VERIFY-LAB: add_text options (legacy: addCustomText), label layer in the
# stream map (TEXT entry), whether the X-FAB LVS deck wants labels on
# another layer (pin/text purpose).
# ------------------------------------------------------------------------
if {![info exists PAD_PIN]} { set PAD_PIN PAD }
array set supplyOf [list $PAD_VDD VDD $PAD_GND GND $PAD_VDDO VDDO $PAD_GNDO GNDO]
set fl [open ${DESIGN_TOP}_labels.txt w]
foreach pc [list $PAD_IN $PAD_IN_ST $PAD_OUT $PAD_BIDIR $PAD_VDD $PAD_GND $PAD_VDDO $PAD_GNDO] {
  foreach inst [get_db insts -if ".base_cell.name==$pc"] {
    if {[info exists supplyOf($pc)]} {
      set label $supplyOf($pc)
    } else {
      set label [get_db [get_db $inst .pins -if ".base_name==$PAD_PIN"] .net.name]
    }
    if {$label eq ""} { continue }
    lassign [lindex [get_db $inst .bbox] 0] x0 y0 x1 y1
    set x [expr {($x0 + $x1) / 2.0}]
    set y [expr {($y0 + $y1) / 2.0}]
    if {[catch {add_text -layer $LABEL_LAYER -label $label -pt [list $x $y] -height 5}]} {
      addCustomText $LABEL_LAYER $label $x $y 5
    }
    puts $fl "$label $x $y"
  }
}
close $fl

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
