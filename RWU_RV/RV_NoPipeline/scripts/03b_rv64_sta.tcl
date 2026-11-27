#===============================================================================
# 03b_rv64_sta.tcl
#
# Tempus script (Stylus UI): sign-off static timing analysis of the routed
# cc_chip_top (X-FAB XH018) with the Quantus parasitics.
#
# Inputs (variables may be set before sourcing; defaults = build directories
# of the wrapper scripts, relative to the run directory build_sta/):
#   NETLIST   routed netlist from Innovus  (../build_innovus/cc_chip_top_routed.v)
#   SPEF_DIR  Quantus SPEF per RC corner   (../build_quantus)
#   SI        1 = crosstalk delay (coupling capacitances in the SPEF), 0 = off
#   XFAB_PATHS (environment) Liberty files of the corners, as for Genus
#
# Views (xh018_mmmc_sta.tcl):
#   setup  av_slow av_typ av_jtag_slow av_scan_slow
#   hold   av_fast av_jtag_fast av_scan_fast
#
# Outputs in the run directory:
#   sta_check_timing.rpt       unconstrained endpoints, missing clocks, loops
#   sta_coverage.rpt           which checks are analysed in which view
#   sta_setup_<view>.rpt       20 worst setup paths per setup view
#   sta_hold_<view>.rpt        20 worst hold paths per hold view
#   sta_violators.rpt          all violations: timing and DRV (transition,
#                              capacitance, fanout)
#   sta_summary.txt            worst slack per view, read by scripts/sta/sta.sh
#   cc_chip_top_sta_func.sdf   SDF min = av_fast, max = av_slow   (GLS)
#   cc_chip_top_sta_scan.sdf   SDF min/max of the scan views      (GLS 'scan')
#
# Usage: scripts/sta/sta.sh (see its --help), or in build_sta/:
#   tempus -stylus -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/03b_rv64_sta.tcl
#===============================================================================

set DESIGN_TOP cc_chip_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]

if {![info exists ::env(XFAB_PATHS)] || ![file readable $::env(XFAB_PATHS)]} {
  error "XFAB_PATHS must point to the local X-FAB path file (see $SCRIPT_DIR/xh018_paths_template.tcl)"
}
source $::env(XFAB_PATHS)

if {![info exists NETLIST]}  { set NETLIST  ../build_innovus/${DESIGN_TOP}_routed.v }
if {![info exists SPEF_DIR]} { set SPEF_DIR ../build_quantus }
if {![info exists SI]}       { set SI 1 }

set SETUP_VIEWS {av_slow av_typ av_jtag_slow av_scan_slow}
set HOLD_VIEWS  {av_fast av_jtag_fast av_scan_fast}

# ------------------------------------------------------------------------
# 1. Design: MMMC (libraries, corners, modes), netlist, parasitics
# ------------------------------------------------------------------------
read_mmmc    $SCRIPT_DIR/xh018_mmmc_sta.tcl
read_netlist $NETLIST -top $DESIGN_TOP
init_design

foreach rc {rc_max rc_typ rc_min} {
  read_spef -rc_corner $rc $SPEF_DIR/${DESIGN_TOP}_${rc}.spef
}

# ------------------------------------------------------------------------
# 2. Analysis settings
# ------------------------------------------------------------------------
# On-chip variation with common path pessimism removal: launch and capture
# clock share the clock tree up to the branch point, that part must not be
# counted twice (matters most for hold).
set_db timing_analysis_type ocv
set_db timing_analysis_cppr both
# Crosstalk: neighbouring nets switching change the delay; needs the
# coupling capacitances that rc_coupled extraction writes into the SPEF.
if {$SI} { set_db delaycal_enable_si true }

# ------------------------------------------------------------------------
# 3. Reports
# ------------------------------------------------------------------------
check_timing -verbose        > sta_check_timing.rpt
report_analysis_coverage     > sta_coverage.rpt

foreach view $SETUP_VIEWS {
  report_timing -late  -view $view -max_paths 20 > sta_setup_${view}.rpt
}
foreach view $HOLD_VIEWS {
  report_timing -early -view $view -max_paths 20 > sta_hold_${view}.rpt
}
report_constraint -all_violators > sta_violators.rpt

# Worst slack per view, one line each: "<setup|hold> <view> <slack|n/a>".
# Summary for the wrapper; the reports above are the reference.
proc as_worst_slack {check view} {
  set el [expr {$check eq "setup" ? "-late" : "-early"}]
  if {[catch {
    set p [report_timing $el -view $view -max_paths 1 -collection]
    set s [get_property $p slack]
  }]} { return n/a }
  if {$s eq ""} { return n/a }
  return $s
}
set fd [open sta_summary.txt w]
foreach view $SETUP_VIEWS { puts $fd "setup $view [as_worst_slack setup $view]" }
foreach view $HOLD_VIEWS  { puts $fd "hold  $view [as_worst_slack hold  $view]" }
close $fd

# ------------------------------------------------------------------------
# 4. SDF for the post-route gate-level simulation (scripts/gatesim -p -s)
# ------------------------------------------------------------------------
# A case analysis can drop the timing arcs it disables from the SDF, so the
# scan test gets its own SDF, written from the scan views.
write_sdf -min_view av_fast      -max_view av_slow      ${DESIGN_TOP}_sta_func.sdf
write_sdf -min_view av_scan_fast -max_view av_scan_slow ${DESIGN_TOP}_sta_scan.sdf
