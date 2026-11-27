#===============================================================================
# rv64_rtl_setup.tcl
#
# RTL of RV_NoPipeline for the X-FAB XH018 tools: file list and Verilog
# defines. Sourced by 00_rv64_elab.tcl (Genus) and 04_rv64_lec.tcl (Conformal
# LEC, golden RTL), so both read exactly the same design.
#
# Expects DESIGN_PATH (asgithub root) and the variables of the local path
# file $XFAB_PATHS (cell and pin names for the defines). Plain Tcl, no tool
# command. Keep the file list in step with the other file lists
# (sim/, cocotb/, 01a_rv64_sim.tcl).
#===============================================================================

# Order matches the verified xvlog compile order from the xsim run
# (tb/xvlog.log) -- as_pack.sv (package) must be read first, as_top_mem.sv
# last. Do not add ip_jtag/src/as_pack.sv: it redefines package as_pack
# and is superseded by the RV_NoPipeline version.
set RTL_FILES [list \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/as_pack.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/asRegFile.sv" \
  "$DESIGN_PATH/ip_clkcells/src/cc_clk_mux2.sv" \
  "$DESIGN_PATH/ip_clkcells/src/cc_clk_gate.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/cc_bscan.sv" \
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
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/cc_pad_in.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/cc_pad_out.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/cc_pad_bidir.sv" \
  "$DESIGN_PATH/RWU_RV/RV_NoPipeline/src/cc_chip_top.sv" \
]

# XFAB_SPRAM selects the SPRAM macros in as_imem / as_dmem_core, XFAB_PADS the
# IO_CELLS_3V cells in cc_pad_* and the supply pads in cc_chip_top,
# XFAB_CLKCELLS the D_CELLS_HD clock mux and clock gate in cc_clk_mux2 /
# cc_clk_gate, instead of the behavioural models. All cell and pin names come
# from $XFAB_PATHS, so that no X-FAB name is part of the repository.
# XFAB_DFT leaves the scan chain hookup in as_top_mem open for
# connect_scan_chains (01b_rv64_syn.tcl).
set RTL_DEFINES [list XFAB_SPRAM \
                        XFAB_DFT \
                        XFAB_CLKCELLS \
                        XFAB_CLKMUX=$CLKMUX \
                        XFAB_CLKMUX_I0=$CLKMUX_I0 \
                        XFAB_CLKMUX_I1=$CLKMUX_I1 \
                        XFAB_CLKMUX_S=$CLKMUX_S \
                        XFAB_CLKMUX_Q=$CLKMUX_Q \
                        XFAB_ICG=$ICG \
                        XFAB_ICG_CK=$ICG_CK \
                        XFAB_ICG_E=$ICG_E \
                        XFAB_ICG_TE=$ICG_TE \
                        XFAB_ICG_Q=$ICG_Q \
                        XFAB_IMEM_MACRO=$IMEM_MACRO \
                        XFAB_DMEM_MACRO=$DMEM_MACRO \
                        XFAB_PADS \
                        XFAB_PAD_IN=$PAD_IN \
                        XFAB_PAD_IN_ST=$PAD_IN_ST \
                        XFAB_PAD_OUT=$PAD_OUT \
                        XFAB_PAD_BIDIR=$PAD_BIDIR \
                        XFAB_PAD_VDD=$PAD_VDD \
                        XFAB_PAD_GND=$PAD_GND \
                        XFAB_PAD_VDDO=$PAD_VDDO \
                        XFAB_PAD_GNDO=$PAD_GNDO]
