#===============================================================================
# 01b_rv64_syn.tcl
#
# Genus script: logic synthesis of RV_NoPipeline (as_top_mem)
# Technology:   X-FAB xh035
#
# Builds on the elaboration checkpoint written by 00_rv64_elab.tcl
# (as_top_mem_elab.db) -- run 00_rv64_elab.tcl first, in the same
# run directory.
#
# Usage (from a Genus shell):
#   genus -files ./scripts/01b_rv64_syn.tcl
# or interactively:
#   genus -> source ./scripts/01b_rv64_syn.tcl
#===============================================================================

set DESIGN_TOP as_top_mem

# ------------------------------------------------------------------------
# 1. Restore elaborated design from 00_rv64_elab.tcl
# ------------------------------------------------------------------------
# read_db restores libraries, RTL and elaboration state as saved by
# write_db -all_root_attributes in 00_rv64_elab.tcl.
read_db ${DESIGN_TOP}_elab.db

# ------------------------------------------------------------------------
# 2. Timing constraints (SDC)
# ------------------------------------------------------------------------
# Placeholder constraints -- replace with a dedicated constraints.sdc once
# the target frequency for xh035 is known. clk_i / tck_i port names are
# taken from src/asTopMem.sv.
create_clock -name clk_i -period 20.000 [get_ports clk_i]   ;# 50 MHz placeholder
create_clock -name tck_i -period 100.000 [get_ports tck_i]  ;# JTAG TCK, placeholder

# JTAG TCK and the functional clock are unrelated -- do not time-analyze
# paths between them.
set_clock_groups -asynchronous -group {clk_i} -group {tck_i}

# Asynchronous resets: no meaningful setup/hold relationship to any clock.
set_false_path -from [get_ports rst_i]
set_false_path -from [get_ports trst_i]

set_input_delay  -clock clk_i 2.000 [remove_from_collection [all_inputs]  [get_ports {clk_i rst_i tck_i trst_i tms_i tdi_i}]]
set_output_delay -clock clk_i 2.000 [all_outputs]

# ------------------------------------------------------------------------
# 3. Synthesis effort
# ------------------------------------------------------------------------
set_db syn_generic_effort medium
set_db syn_map_effort     medium
set_db syn_opt_effort     medium

# ------------------------------------------------------------------------
# 4. Run synthesis
# ------------------------------------------------------------------------
# TODO (per README_XFAB.txt, Bemerkungen): SRAMs must be integrated as
# black-box macros BEFORE this step. as_dmem_core / as_imem are currently
# plain RTL memories (no SRAM macro yet) -- revisit this script once SRAM
# integration is done, so read_db above also carries the macro views.
syn_generic
syn_map
syn_opt

# ------------------------------------------------------------------------
# 5. Reports
# ------------------------------------------------------------------------
report_area                          > ${DESIGN_TOP}_area.rpt
report_timing                        > ${DESIGN_TOP}_timing.rpt
report_gates                         > ${DESIGN_TOP}_gates.rpt
report_power                         > ${DESIGN_TOP}_power.rpt
check_design -unresolved

# ------------------------------------------------------------------------
# 6. Outputs for the next stage (Gate-Level Simulation / DFT)
# ------------------------------------------------------------------------
write_hdl                  > ${DESIGN_TOP}_syn.v
write_sdc                  > ${DESIGN_TOP}_syn.sdc
write_db -all_root_attributes ${DESIGN_TOP}_syn.db
