#===============================================================================
# 00_rv64_elab.tcl
#
# Genus script: read libraries (MMMC), LEF and RTL, elaborate RV_NoPipeline
# (as_top_mem) and write the checkpoint for 01b_rv64_syn.tcl.
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
set DESIGN_TOP  as_top_mem

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
# 4. RTL file list (SystemVerilog)
# ------------------------------------------------------------------------
# Order matches the verified xvlog compile order from the xsim run
# (tb/xvlog.log) -- as_pack.sv (package) must be read first, as_top_mem.sv
# last. Do not add ip_jtag/src/as_pack.sv: it redefines package as_pack
# and is superseded by the RV_NoPipeline version.
set RTL_FILES [list \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/as_pack.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asRegFile.sv" \
  "$DESIGN_PATH/ip_dmem/src/asDMemBack.sv" \
  "$DESIGN_PATH/ip_dmem/src/asDMemFront.sv" \
  "$DESIGN_PATH/ip_dmem/src/asDMemCore.sv" \
  "$DESIGN_PATH/ip_dmem/src/asDMem.sv" \
  "$DESIGN_PATH/ip_dmem/src/asDMemTop.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asIMem.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asAlu.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asAluBr.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asInstrDecode.sv" \
  "$DESIGN_PATH/ip_jtag/src/tap_fsm.sv" \
  "$DESIGN_PATH/ip_jtag/src/ir_cell.sv" \
  "$DESIGN_PATH/ip_jtag/src/dr_cell.sv" \
  "$DESIGN_PATH/ip_jtag/src/scan_cell.sv" \
  "$DESIGN_PATH/ip_jtag/src/by_cell.sv" \
  "$DESIGN_PATH/ip_jtag/src/ir_reg.sv" \
  "$DESIGN_PATH/ip_jtag/src/dr_reg.sv" \
  "$DESIGN_PATH/ip_jtag/src/ir_decode.sv" \
  "$DESIGN_PATH/ip_jtag/src/jtag.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asMBpi.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asSBpi.sv" \
  "$DESIGN_PATH/ip_gpio/src/asGpio.sv" \
  "$DESIGN_PATH/ip_irqper/src/as_irq_peripheral.sv" \
  "$DESIGN_PATH/ip_gpio/src/asGpioTop.sv" \
  "$DESIGN_PATH/ip_trapcsr/src/cc_trap_csr.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asCPUx.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asDecode.sv" \
  "$DESIGN_PATH/ip_cgu/src/asCguCore.sv" \
  "$DESIGN_PATH/ip_cgu/src/asCguTop.sv" \
  "$DESIGN_PATH/ip_fifo/src/as_fifo.sv" \
  "$DESIGN_PATH/ip_uart_v2/src/as_uart_top.sv" \
  "$DESIGN_PATH/ip_icu/src/cc_icu.sv" \
  "$DESIGN_PATH/ip_icu/src/cc_icu_top.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asTopMem.sv" \
]

# ------------------------------------------------------------------------
# 5. Read, elaborate, bind constraints
# ------------------------------------------------------------------------
# XFAB_SPRAM selects the SPRAM macros in as_imem / as_dmem_core instead of
# the behavioural models. The macro cell names come from $XFAB_PATHS, so that
# no X-FAB cell name is part of the repository.
read_hdl -sv -define [list XFAB_SPRAM \
                           XFAB_IMEM_MACRO=$IMEM_MACRO \
                           XFAB_DMEM_MACRO=$DMEM_MACRO] $RTL_FILES
elaborate $DESIGN_TOP
init_design

# ------------------------------------------------------------------------
# 6. Sanity checks / reports
# ------------------------------------------------------------------------
check_design -unresolved
check_timing_intent
report_summary
write_html_report -filename ${DESIGN_TOP}_elab_summary.html

# ------------------------------------------------------------------------
# 7. Checkpoint for the next stage (01b synthesis script)
# ------------------------------------------------------------------------
write_db -all_root_attributes ${DESIGN_TOP}_elab.db
