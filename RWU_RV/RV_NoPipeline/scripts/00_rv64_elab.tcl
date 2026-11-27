#===============================================================================
# 00_rv64_elab.tcl
#
# Genus script: read libraries (MMMC), LEF and RTL, elaborate RV_NoPipeline
# (chip top cc_chip_top = pad ring + as_top_mem) and write the checkpoint for
# 01b_rv64_syn.tcl.
# Technology:   X-FAB XH018 (4 metal layers, LPMOS),
#               D_CELLS_HD, IO_CELLS_3V, SPRAM macros for I-Mem / D-Mem
#
# Before running:
#   XFAB_PATHS = local path file with the X-FAB file locations (NDA, not in
#                git; template: scripts/xh018_paths_template.tcl)
#
# Usage (run directory of your choice, e.g. RV_NoPipeline/syn/genus):
#   genus -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/00_rv64_elab.tcl
#===============================================================================

# ------------------------------------------------------------------------
# 1. Paths
# ------------------------------------------------------------------------
set SCRIPT_DIR  [file dirname [file normalize [info script]]]
set DESIGN_PATH [file normalize $SCRIPT_DIR/../../..]
set DESIGN_TOP  cc_chip_top

if {![info exists ::env(XFAB_PATHS)] || ![file readable $::env(XFAB_PATHS)]} {
  error "XFAB_PATHS must point to the local X-FAB path file (see $SCRIPT_DIR/xh018_paths_template.tcl)"
}
source $::env(XFAB_PATHS)

foreach f [concat $LIBS_SLOW $LIBS_TYP $LIBS_FAST $LEF_FILES \
                  $CAPTBL_MAX $CAPTBL_TYP $CAPTBL_MIN $QRC_MAX $QRC_TYP $QRC_MIN] {
  if {![file readable $f]} { error "X-FAB file not found: $f" }
}

# ------------------------------------------------------------------------
# 2. Genus global settings
# ------------------------------------------------------------------------
set_db information_level 7
set_db hdl_track_filename_row_col true
set_db max_cpus_per_server 4

# ------------------------------------------------------------------------
# 3. Technology: libraries per corner (MMMC) and physical data
# ------------------------------------------------------------------------
read_mmmc $SCRIPT_DIR/xh018_mmmc.tcl
read_physical -lef $LEF_FILES

# ------------------------------------------------------------------------
# 4. RTL file list and defines (shared with Conformal LEC)
# ------------------------------------------------------------------------
source $SCRIPT_DIR/rv64_rtl_setup.tcl

# ------------------------------------------------------------------------
# 5. Read, elaborate, bind constraints
# ------------------------------------------------------------------------
read_hdl -sv -define $RTL_DEFINES $RTL_FILES
elaborate $DESIGN_TOP
init_design

# ------------------------------------------------------------------------
# 6. Sanity checks / reports
# ------------------------------------------------------------------------
check_design -unresolved
check_timing_intent
report_summary

# ------------------------------------------------------------------------
# 7. Checkpoint for the next stage (01b synthesis script)
# ------------------------------------------------------------------------
write_db -all_root_attributes ${DESIGN_TOP}_elab.db
