#===============================================================================
# xh018_mmmc_sta.tcl
#
# Multi-mode multi-corner setup for the sign-off STA in Tempus
# (03b_rv64_sta.tcl). Builds on xh018_mmmc.tcl (Genus/Innovus: modes func and
# jtag_load) and adds the constraint mode scan (as_top_mem_scan.sdc), which
# only the STA checks.
#
# The RC corners of xh018_mmmc.tcl stay: Tempus takes the parasitics from the
# Quantus SPEF per RC corner (read_spef -rc_corner), not from the QRC files.
#
# Expects the variables of the local path file ($XFAB_PATHS) and SCRIPT_DIR.
#===============================================================================

source $SCRIPT_DIR/xh018_mmmc.tcl

create_constraint_mode -name scan \
  -sdc_files [list $SCRIPT_DIR/as_top_mem.sdc $SCRIPT_DIR/as_top_mem_scan.sdc]

create_analysis_view -name av_scan_slow -constraint_mode scan -delay_corner dc_slow
create_analysis_view -name av_scan_fast -constraint_mode scan -delay_corner dc_fast

set_analysis_view -setup {av_slow av_typ av_jtag_slow av_scan_slow} \
                  -hold  {av_fast av_jtag_fast av_scan_fast}
