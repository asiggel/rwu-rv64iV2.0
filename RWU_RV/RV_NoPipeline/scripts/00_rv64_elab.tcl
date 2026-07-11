#===============================================================================
# 00_rv64_elab.tcl
#
# Genus script: collect RTL and elaborate RV_NoPipeline (as_top_mem)
# Technology:   X-FAB xh035
#
# Usage (from a Genus shell):
#   genus -legacy_ui -files ./scripts/00_rv64_elab.tcl
# or interactively:
#   genus -> source ./scripts/00_rv64_elab.tcl
#===============================================================================

# ------------------------------------------------------------------------
# 1. Paths -- adjust before running on the Cadence workstation
# ------------------------------------------------------------------------
# <path-to-pdk>    : root of the xh035 PDK-Kernel install (xenv-cadence),
#                    the directory that contains xh035-D_CELLS-liberty_MOS
# <path-to-design> : root of the asgithub checkout (contains RWU_RV/ and
#                    the ip_* peripheral IP directories as siblings)
set PDK_PATH    <path-to-pdk>
set DESIGN_PATH <path-to-design>

set DESIGN_TOP  as_top_mem

# ------------------------------------------------------------------------
# 2. Genus global settings
# ------------------------------------------------------------------------
set_db information_level 7
set_db hdl_track_filename_row_col true
set_db max_cpus_per_server 4

# ------------------------------------------------------------------------
# 3. Technology library (xh035)
# ------------------------------------------------------------------------
# Liberty file names are placeholders -- replace with the actual .lib file
# names shipped in xh035-D_CELLS-liberty_MOS once available.
set_db init_lib_search_path [list \
  "$PDK_PATH/xh035-D_CELLS-liberty_MOS" \
]

set_db library [list \
  xh035_dcells_typ_3p3v_25c.lib \
]

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
  "$DESIGN_PATH/ip_gpio/src/asGpioTop.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asCPUx.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asDecode.sv" \
  "$DESIGN_PATH/ip_cgu/src/asCguCore.sv" \
  "$DESIGN_PATH/ip_cgu/src/asCguTop.sv" \
  "$DESIGN_PATH/ip_fifo/src/as_fifo.sv" \
  "$DESIGN_PATH/ip_uart_v2/src/as_uart_top.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asTopMem.sv" \
]

# ------------------------------------------------------------------------
# 5. Read and elaborate
# ------------------------------------------------------------------------
read_hdl -sv $RTL_FILES
elaborate $DESIGN_TOP

# ------------------------------------------------------------------------
# 6. Sanity checks / reports
# ------------------------------------------------------------------------
check_design -unresolved
report_summary
write_html_report -filename ${DESIGN_TOP}_elab_summary.html

# ------------------------------------------------------------------------
# 7. Checkpoint for the next stage (01_ synthesis script)
# ------------------------------------------------------------------------
write_db -all_root_attributes ${DESIGN_TOP}_elab.db
