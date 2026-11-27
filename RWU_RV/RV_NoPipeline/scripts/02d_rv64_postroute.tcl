#===============================================================================
# 02d_rv64_postroute.tcl
#
# Innovus, second step: post-route optimization and finishing of cc_chip_top
# (X-FAB XH018). Starts from cc_chip_top_routed.db (02_rv64_floorplan_pnr.tcl)
# and writes the final layout:
#
#   opt     timing with post-route extraction, setup/hold/DRV optimization
#   finish  core fillers, metal fill, final checkpoint, hand-off netlists
#           and DEF (02b_rv64_export.tcl)
#   gds     merged GDS with pad labels (02c_rv64_gds.tcl)
#
# Why a separate step: the optimization inserts and resizes cells, so it
# must come after routing but before the fillers and the metal fill, and
# the hand-off files must show the optimized layout.
#
# Hold views: Genus/Innovus have no scan mode (xh018_mmmc.tcl). Here the
# hold view av_scan_fast (as_top_mem_scan.sdc) is added: hold in scan shift
# is the classic post-CTS problem and must be fixed in the layout. Setup in
# scan mode stays out (it only limits TCK in SCANTEST, see 06_DokuSTA).
#
# Variables (set before sourcing, normally by scripts/innovus/innovus_post.sh):
#   STOP_AFTER       opt | finish | gds (default gds)
#   EXTRACT_EFFORT   medium (built-in extractor, default) | high | signoff
#                    (high/signoff run the Quantus engine, needs a licence)
#
# Outputs (run directory build_innovus/):
#   cc_chip_top_post_{setup,hold}_pre.rpt   worst paths before optimization
#   cc_chip_top_final_{timing,hold}.rpt     worst paths after optimization
#   cc_chip_top_postopt.db                  checkpoint after optimization
#   cc_chip_top_final.db                    final layout (fillers, fill)
#   cc_chip_top_density.rpt, _final_area.rpt, _connectivity.rpt, ...
#   cc_chip_top_routed.v/.def, _lvs.v, cc_chip_top.gds  (02b, 02c)
#
# VERIFY-LAB (first run): opt_design / time_design options in Innovus 26.1,
# creating a constraint mode and view on an initialized design, attribute
# names of the extraction and SI settings.
#===============================================================================

set DESIGN_TOP cc_chip_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]

if {![info exists ::env(XFAB_PATHS)] || ![file readable $::env(XFAB_PATHS)]} {
  error "XFAB_PATHS must point to the local X-FAB path file (see $SCRIPT_DIR/xh018_paths_template.tcl)"
}
source $::env(XFAB_PATHS)

if {![info exists STOP_AFTER]}     { set STOP_AFTER gds }
if {![info exists EXTRACT_EFFORT]} { set EXTRACT_EFFORT medium }
proc as_stop_here {stage} {
  global STOP_AFTER
  if {$STOP_AFTER eq $stage} {
    puts "AS-post: stopped after stage '$stage' (STOP_AFTER)."
    return 1
  }
  return 0
}

# ------------------------------------------------------------------------
# 1. Routed design from 02_rv64_floorplan_pnr.tcl
# ------------------------------------------------------------------------
read_db ${DESIGN_TOP}_routed.db

# ------------------------------------------------------------------------
# 2. Views: add the scan-shift hold view
# ------------------------------------------------------------------------
create_constraint_mode -name scan \
  -sdc_files [list $SCRIPT_DIR/as_top_mem.sdc $SCRIPT_DIR/as_top_mem_scan.sdc]
create_analysis_view -name av_scan_fast -constraint_mode scan -delay_corner dc_fast
set_analysis_view -setup {av_slow av_typ av_jtag_slow} \
                  -hold  {av_fast av_jtag_fast av_scan_fast}

# ------------------------------------------------------------------------
# 3. Analysis settings: as in the sign-off STA (03b_rv64_sta.tcl)
# ------------------------------------------------------------------------
set_db extract_rc_engine       post_route
set_db extract_rc_effort_level $EXTRACT_EFFORT
set_db extract_rc_coupled      true
set_db timing_analysis_type    ocv
set_db timing_analysis_cppr    both
set_db delaycal_enable_si      true

# ------------------------------------------------------------------------
# 4. Timing before the optimization (reference)
# ------------------------------------------------------------------------
time_design -post_route        -report_dir timing_pre -report_prefix pre
time_design -post_route -hold  -report_dir timing_pre -report_prefix pre_hold
report_timing -late  -max_paths 20 > ${DESIGN_TOP}_post_setup_pre.rpt
report_timing -early -max_paths 20 > ${DESIGN_TOP}_post_hold_pre.rpt

# ------------------------------------------------------------------------
# 5. Post-route optimization: setup, hold, DRV (max transition /
#    capacitance / fanout). Hold fixing inserts delay cells or buffers in
#    the data paths; the router makes the ECO routes itself.
# ------------------------------------------------------------------------
opt_design -post_route -setup -hold
opt_design -post_route -drv

time_design -post_route        -report_dir timing_post -report_prefix post
time_design -post_route -hold  -report_dir timing_post -report_prefix post_hold
report_timing -late  -max_paths 20 > ${DESIGN_TOP}_final_timing.rpt
report_timing -early -max_paths 20 > ${DESIGN_TOP}_final_hold.rpt
write_db ${DESIGN_TOP}_postopt.db
if {[as_stop_here opt]} { return }

# ------------------------------------------------------------------------
# 6. Core fillers and metal fill (after the last cell change)
# ------------------------------------------------------------------------
# Fillers close the gaps in the rows, so the wells, implants and supply rails
# are continuous (DRC). Physical only: not in the STA/GLS netlist.
add_fillers -base_cells $CORE_FILLERS

# Metal fill: dummy metal in empty areas, so that every layer reaches the
# minimum density per window that CMP needs (DRC density rules). Before the
# export: Quantus extracts the fill as well (it adds capacitance), and the
# GDS carries it. Floating fill, density targets from the technology LEF.
# VERIFY-LAB: options in Innovus 26.1 (legacy addMetalFill /
# verifyMetalDensity); whether X-FAB requires its own fill deck
# (Pegasus/Calibre) instead -- then remove this step.
add_metal_fill -layers $FILL_LAYERS
if {[catch {check_metal_density -report ${DESIGN_TOP}_density.rpt}]} {
  verifyMetalDensity -report ${DESIGN_TOP}_density.rpt
}

summaryReport -outfile ${DESIGN_TOP}_final_summary.rpt
verify_connectivity -type all > ${DESIGN_TOP}_connectivity.rpt
report_area                   > ${DESIGN_TOP}_final_area.rpt
write_db ${DESIGN_TOP}_final.db

# ------------------------------------------------------------------------
# 7. Hand-off: netlists and DEF of the final layout (02b_rv64_export.tcl)
# ------------------------------------------------------------------------
source $SCRIPT_DIR/02b_rv64_export.tcl
if {[as_stop_here finish]} { return }

# ------------------------------------------------------------------------
# 8. Merged GDS for DRC / LVS (02c_rv64_gds.tcl)
# ------------------------------------------------------------------------
source $SCRIPT_DIR/02c_rv64_gds.tcl
