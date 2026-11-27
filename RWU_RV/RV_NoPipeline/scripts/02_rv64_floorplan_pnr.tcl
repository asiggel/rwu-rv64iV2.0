#===============================================================================
# 02_rv64_floorplan_pnr.tcl
#
# Innovus script: floorplan, pad-ring placement, standard-cell placement,
# CTS and routing for cc_chip_top (X-FAB XH018). Writes the routed netlist and
# DEF for Quantus, Tempus and the post-route gate-level simulation.
#
# FIRST-PASS SMOKE TEST (spec section 4.1.3 / TECH-06 still open):
#   - The 26 pad-ring cells are placed in plain netlist order around the
#     four sides, not checked against the IO_CELLS_3V databook.
#   - No power ring / stripes yet (Phase 2 item, not reached here).
#
# Die size and IO-ring depth come from spec section 4.1.3:
#   - core ~3.5-4.5 mm^2 / ~2 mm side  (measured synth. area: 3.04 mm^2)
#   - die side ~2.5-2.7 mm, core-limited (26 pads, ring mostly filler)
#   -> die 2600 x 2600 um, IO ring depth = pad cell height (257 um)
#
# Before running:
#   01b_rv64_syn.tcl must have written innovus/cc_chip_top.db. Libraries,
#   LEF, MMMC and SDC come in with that DB.
#   XFAB_PATHS = local X-FAB path file (NDA, not in git): this script takes
#                the site, pad, corner and IO filler cell names from it
#                (template: scripts/xh018_paths_template.tcl)
#
# Usage (same run directory as the Genus scripts, e.g. RV_NoPipeline/syn/genus):
#   innovus -batch -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/02_rv64_floorplan_pnr.tcl
# or with GUI / step by step / DRC + antenna summary:
#   scripts/innovus/innovus_pnr.sh  (see its --help)
#===============================================================================

set DESIGN_TOP cc_chip_top

if {![info exists ::env(XFAB_PATHS)] || ![file readable $::env(XFAB_PATHS)]} {
  error "XFAB_PATHS must point to the local X-FAB path file (see scripts/xh018_paths_template.tcl)"
}
source $::env(XFAB_PATHS)

# Optional stop point for step-by-step runs (scripts/innovus/innovus_pnr.sh
# -s): fp | place | cts | route. Not set = full flow.
if {![info exists STOP_AFTER]} { set STOP_AFTER route }
proc as_stop_here {stage} {
  global STOP_AFTER
  if {$STOP_AFTER eq $stage} {
    puts "AS-pnr: stopped after stage '$stage' (STOP_AFTER)."
    return 1
  }
  return 0
}

# ------------------------------------------------------------------------
# 1. Read the common DB checkpoint written by Genus (01b_rv64_syn.tcl)
# ------------------------------------------------------------------------
read_db innovus/${DESIGN_TOP}.db

# ------------------------------------------------------------------------
# 2. Floorplan: die 2600x2600um, IO ring depth 257um on all sides
# ------------------------------------------------------------------------
set DIE_W       2600.0
set DIE_H       2600.0
set CORE_SIZE   2086.0
set IO_RING     257.0
set PAD_W       60.0
set CORNER_CELL $PAD_CORNER

# floorPlan on this site/tech already reserves an implicit ~257um margin
# on every side on top of whatever margin is given here -- verified
# empirically (margin 0 -> core_bbox {257 257 2343 2343}, i.e. exactly the
# intended core-to-die gap). Core size is given directly (-s) to avoid
# relying on that implicit margin for the die-size (-d) form as well.
floorPlan -site $CORE_SITE -s $CORE_SIZE $CORE_SIZE 0 0 0 0

# ------------------------------------------------------------------------
# 3. Pad-ring placement (first-pass, netlist order -- TECH-06 open)
# ------------------------------------------------------------------------
set padCellNames [list $PAD_IN $PAD_IN_ST $PAD_OUT $PAD_BIDIR \
                        $PAD_VDD $PAD_GND $PAD_VDDO $PAD_GNDO]
set padInsts {}
foreach pc $padCellNames {
  foreach i [get_db insts -if ".base_cell.name==$pc"] {
    lappend padInsts [get_db $i .name]
  }
}
set nPads [llength $padInsts]
puts "AS-pnr: found $nPads pad instances for the ring (expected 26)."
if {$nPads != 26} {
  error "AS-pnr: expected 26 pad instances, found $nPads -- check padCellNames against \$XFAB_PATHS"
}

# Distribute in 4 contiguous blocks: bottom, right, top, left.
set perSide [expr {int(ceil(double($nPads)/4.0))}]
array set sideInsts {bottom {} right {} top {} left {}}
set sides {bottom right top left}
set idx 0
foreach inst $padInsts {
  set side [lindex $sides [expr {$idx/$perSide}]]
  lappend sideInsts($side) $inst
  incr idx
}

proc as_place_side {side insts dieW dieH ioRing padW} {
  if {[llength $insts] == 0} { return }
  switch $side {
    bottom { set y 0.0;                    set ori R0 }
    top    { set y [expr {$dieH-$ioRing}]; set ori R180 }
    left   { set x 0.0;                    set ori R270 }
    right  { set x [expr {$dieW-$ioRing}]; set ori R90 }
  }
  set pos $ioRing
  foreach inst $insts {
    if {$side in {bottom top}} {
      placeInstance $inst [list $pos $y] $ori -fixed
    } else {
      placeInstance $inst [list $x $pos] $ori -fixed
    }
    set pos [expr {$pos + $padW}]
  }
  puts "AS-pnr: placed [llength $insts] pad(s) on side '$side'."
}

as_place_side bottom $sideInsts(bottom) $DIE_W $DIE_H $IO_RING $PAD_W
as_place_side right  $sideInsts(right)  $DIE_W $DIE_H $IO_RING $PAD_W
as_place_side top    $sideInsts(top)    $DIE_W $DIE_H $IO_RING $PAD_W
as_place_side left   $sideInsts(left)   $DIE_W $DIE_H $IO_RING $PAD_W

# ------------------------------------------------------------------------
# 4. Corner cells (not in the netlist; added here as physical-only)
# ------------------------------------------------------------------------
addInst -cell $CORNER_CELL -inst IOCORNER_BL -physical -place_status fixed \
        -loc [list 0.0 0.0] -ori R0
addInst -cell $CORNER_CELL -inst IOCORNER_BR -physical -place_status fixed \
        -loc [list [expr {$DIE_W-$IO_RING}] 0.0] -ori MY
addInst -cell $CORNER_CELL -inst IOCORNER_TR -physical -place_status fixed \
        -loc [list [expr {$DIE_W-$IO_RING}] [expr {$DIE_H-$IO_RING}]] -ori R180
addInst -cell $CORNER_CELL -inst IOCORNER_TL -physical -place_status fixed \
        -loc [list 0.0 [expr {$DIE_H-$IO_RING}]] -ori MX

# ------------------------------------------------------------------------
# 5. IO-ring fillers (close remaining gaps on all 4 sides)
# ------------------------------------------------------------------------
set fillerCells $PAD_FILLERS
foreach s {bottom top left right} {
  addIoFiller -cell $fillerCells -side $s -fillAnyGap
}

# ------------------------------------------------------------------------
# 6. Checkpoint after floorplan + pad ring
# ------------------------------------------------------------------------
write_db ${DESIGN_TOP}_fp.db
summaryReport -outfile ${DESIGN_TOP}_fp_summary.rpt
if {[as_stop_here fp]} { return }

# ------------------------------------------------------------------------
# 7. Standard-cell / macro placement
# ------------------------------------------------------------------------
place_design

write_db ${DESIGN_TOP}_placed.db
report_area    > ${DESIGN_TOP}_placed_area.rpt
if {[as_stop_here place]} { return }

# ------------------------------------------------------------------------
# 8. Clock tree synthesis
# ------------------------------------------------------------------------
create_ccopt_clock_tree_spec
ccopt_design

write_db ${DESIGN_TOP}_cts.db
report_timing -max_paths 10 > ${DESIGN_TOP}_cts_timing.rpt
if {[as_stop_here cts]} { return }

# ------------------------------------------------------------------------
# 9. Routing
# ------------------------------------------------------------------------
routeDesign

# ------------------------------------------------------------------------
# 10. Final reports + checkpoint
# ------------------------------------------------------------------------
summaryReport -outfile ${DESIGN_TOP}_route_summary.rpt
verify_connectivity -type all > ${DESIGN_TOP}_connectivity.rpt
report_area                   > ${DESIGN_TOP}_final_area.rpt
report_timing -max_paths 20   > ${DESIGN_TOP}_final_timing.rpt
write_db ${DESIGN_TOP}_routed.db

# ------------------------------------------------------------------------
# 11. Hand-off to sign-off: routed netlist + DEF (02b_rv64_export.tcl)
# ------------------------------------------------------------------------
source [file join [file dirname [file normalize [info script]]] 02b_rv64_export.tcl]
