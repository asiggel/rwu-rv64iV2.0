#!/bin/bash
#===============================================================================
# 01a_rv64_sim.tcl
#
# RTL simulation of RV_NoPipeline (as_top_mem) with Xcelium (xrun).
# Companion step to 01b_rv64_syn.tcl in the X-FAB design flow (see
# README_XFAB.txt, section 5, step 2: "Compile & RTL Simulation").
#
# NOTE: despite the .tcl name (kept for the 00_/01a_/01b_ step numbering),
# this is a shell script -- xrun's compile/elaborate/run options are given
# on the command line, not through an embedded Tcl interpreter.
#
# Usage:
#   bash ./scripts/01a_rv64_sim.tcl
# or:
#   chmod +x ./scripts/01a_rv64_sim.tcl && ./scripts/01a_rv64_sim.tcl
#===============================================================================

set -e

# ------------------------------------------------------------------------
# Paths -- adjust before running on the Cadence workstation
# ------------------------------------------------------------------------
DESIGN_PATH=<path-to-design>

# ------------------------------------------------------------------------
# RTL file list -- same compile order as 00_rv64_elab.tcl (verified via
# tb/xvlog.log). Do not add ip_jtag/src/as_pack.sv, see 00_rv64_elab.tcl.
# ------------------------------------------------------------------------
RTL_FILES="
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/as_pack.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asRegFile.sv
  $DESIGN_PATH/ip_dmem/src/asDMemBack.sv
  $DESIGN_PATH/ip_dmem/src/asDMemFront.sv
  $DESIGN_PATH/ip_dmem/src/asDMemCore.sv
  $DESIGN_PATH/ip_dmem/src/asDMem.sv
  $DESIGN_PATH/ip_dmem/src/asDMemTop.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asIMem.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asAlu.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asAluBr.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asInstrDecode.sv
  $DESIGN_PATH/ip_jtag/src/tap_fsm.sv
  $DESIGN_PATH/ip_jtag/src/ir_cell.sv
  $DESIGN_PATH/ip_jtag/src/dr_cell.sv
  $DESIGN_PATH/ip_jtag/src/scan_cell.sv
  $DESIGN_PATH/ip_jtag/src/by_cell.sv
  $DESIGN_PATH/ip_jtag/src/ir_reg.sv
  $DESIGN_PATH/ip_jtag/src/dr_reg.sv
  $DESIGN_PATH/ip_jtag/src/ir_decode.sv
  $DESIGN_PATH/ip_jtag/src/jtag.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asMBpi.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asSBpi.sv
  $DESIGN_PATH/ip_gpio/src/asGpio.sv
  $DESIGN_PATH/ip_gpio/src/asGpioTop.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asCPUx.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asDecode.sv
  $DESIGN_PATH/ip_cgu/src/asCguCore.sv
  $DESIGN_PATH/ip_cgu/src/asCguTop.sv
  $DESIGN_PATH/ip_fifo/src/as_fifo.sv
  $DESIGN_PATH/ip_uart_v2/src/as_uart_top.sv
  $DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asTopMem.sv
"

# ------------------------------------------------------------------------
# Testbench -- tb_rv64i_*.sv all define the same module tb_rv64i, i.e.
# they are swappable scenarios; only one may be compiled at a time.
# Swap TB_FILE below to run a different scenario, e.g.:
#   tb_rv64i_allinstructions.sv, tb_rv64i_jtag.sv, tb_rv64i_uart_tx.sv,
#   tb_rv64i_uart_rx.sv, tb_rv64i_readgpioid.sv, tb_rv64i_filldmem.sv, ...
# ------------------------------------------------------------------------
TB_FILE="$DESIGN_PATH/RWU_RV/RV_NoPipeline/tb/tb_rv64i.sv"

# ------------------------------------------------------------------------
# Batch run (default) -- no display required, suitable for off-site work
# ------------------------------------------------------------------------
xrun $RTL_FILES $TB_FILE -top tb_rv64i -access +rwc

# ------------------------------------------------------------------------
# GUI run (SimVision) -- uncomment when working at the Cadence workstation
# ------------------------------------------------------------------------
# xrun -gui $RTL_FILES $TB_FILE -top tb_rv64i -access +rwc
