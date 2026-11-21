#===============================================================================
# xh018_mmmc.tcl
#
# Multi-mode multi-corner setup for RV_NoPipeline (cc_chip_top), X-FAB XH018.
# Read by Genus (read_mmmc in 00_rv64_elab.tcl) and later by Innovus.
# Expects the variables of the local path file ($XFAB_PATHS, see
# xh018_paths_template.tcl) and SCRIPT_DIR to be set.
#
# Two constraint modes: func (CPU runs) and jtag_load (JTAG loads the I-Mem,
# macro clocked by tck_i). Setup is checked at the slow corner, hold at the
# fast corner, in both modes; typ is only reported (func).
#===============================================================================

create_library_set -name libs_slow -timing $LIBS_SLOW
create_library_set -name libs_typ  -timing $LIBS_TYP
create_library_set -name libs_fast -timing $LIBS_FAST

create_timing_condition -name tc_slow -library_sets {libs_slow}
create_timing_condition -name tc_typ  -library_sets {libs_typ}
create_timing_condition -name tc_fast -library_sets {libs_fast}

create_rc_corner -name rc_max -temperature 125 -cap_table $CAPTBL_MAX -qrc_tech $QRC_MAX
create_rc_corner -name rc_typ -temperature 25  -cap_table $CAPTBL_TYP -qrc_tech $QRC_TYP
create_rc_corner -name rc_min -temperature -40 -cap_table $CAPTBL_MIN -qrc_tech $QRC_MIN

create_delay_corner -name dc_slow -timing_condition tc_slow -rc_corner rc_max
create_delay_corner -name dc_typ  -timing_condition tc_typ  -rc_corner rc_typ
create_delay_corner -name dc_fast -timing_condition tc_fast -rc_corner rc_min

create_constraint_mode -name func \
  -sdc_files [list $SCRIPT_DIR/as_top_mem.sdc $SCRIPT_DIR/as_top_mem_func.sdc]
create_constraint_mode -name jtag_load \
  -sdc_files [list $SCRIPT_DIR/as_top_mem.sdc $SCRIPT_DIR/as_top_mem_jtag.sdc]

create_analysis_view -name av_slow      -constraint_mode func      -delay_corner dc_slow
create_analysis_view -name av_typ       -constraint_mode func      -delay_corner dc_typ
create_analysis_view -name av_fast      -constraint_mode func      -delay_corner dc_fast
create_analysis_view -name av_jtag_slow -constraint_mode jtag_load -delay_corner dc_slow
create_analysis_view -name av_jtag_fast -constraint_mode jtag_load -delay_corner dc_fast

set_analysis_view -setup {av_slow av_typ av_jtag_slow} -hold {av_fast av_jtag_fast}
