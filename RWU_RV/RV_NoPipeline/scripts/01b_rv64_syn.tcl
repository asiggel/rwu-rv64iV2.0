#===============================================================================
# 01b_rv64_syn.tcl
#
# Genus script: logic synthesis of RV_NoPipeline (chip top cc_chip_top)
# Technology:   X-FAB XH018 (see 00_rv64_elab.tcl)
#
# Builds on the checkpoint written by 00_rv64_elab.tcl (cc_chip_top_elab.db,
# libraries, LEF, MMMC and SDC included) -- run it first, in the same run
# directory.
#
# Usage:
#   genus -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/01b_rv64_syn.tcl
#===============================================================================

set DESIGN_TOP cc_chip_top

# ------------------------------------------------------------------------
# 1. Restore elaborated design
# ------------------------------------------------------------------------
read_db ${DESIGN_TOP}_elab.db

# ------------------------------------------------------------------------
# 2. Synthesis settings
# ------------------------------------------------------------------------
set_db syn_generic_effort medium
set_db syn_map_effort     medium
set_db syn_opt_effort     medium

# The SDC files refer to core/cgu/CGUCore and core/as_jtag pins. Genus 26.1
# ungroups core/cgu unless told not to, which renames the pin to
# core/cgu_CGUCore/clk_core_o and breaks as_top_mem.sdc on the netlist.
set_db [get_db hinsts core]             .ungroup_ok false
set_db [get_db hinsts core/cgu]         .ungroup_ok false
set_db [get_db hinsts core/cgu/CGUCore]  .ungroup_ok false
set_db [get_db hinsts core/as_jtag]      .ungroup_ok false

# ------------------------------------------------------------------------
# 3. Run synthesis
# ------------------------------------------------------------------------
# as_imem / as_dmem_core instantiate the SPRAM macros (XFAB_SPRAM, see
# 00_rv64_elab.tcl); check_design -unresolved must report none.
syn_generic
syn_map
syn_opt

# ------------------------------------------------------------------------
# 4. Reports (setup views: slow, typ, jtag_slow; hold views: fast, jtag_fast)
# ------------------------------------------------------------------------
check_design -unresolved          > ${DESIGN_TOP}_check.rpt
check_timing_intent               > ${DESIGN_TOP}_timing_intent.rpt
report_area                       > ${DESIGN_TOP}_area.rpt
report_gates                      > ${DESIGN_TOP}_gates.rpt
report_clocks                     > ${DESIGN_TOP}_clocks.rpt
report_qor                        > ${DESIGN_TOP}_qor.rpt
report_power                      > ${DESIGN_TOP}_power.rpt
foreach view {av_slow av_typ av_jtag_slow} {
  report_timing -views $view -max_paths 20 > ${DESIGN_TOP}_timing_${view}.rpt
}

# ------------------------------------------------------------------------
# 5. Outputs: netlist + constraints for Innovus and gate-level simulation
# ------------------------------------------------------------------------
write_hdl                  > ${DESIGN_TOP}_syn.v
write_sdc -view av_slow    > ${DESIGN_TOP}_syn.sdc
write_sdc -view av_jtag_slow > ${DESIGN_TOP}_syn_jtag.sdc
write_sdf -view av_slow    > ${DESIGN_TOP}_syn.sdf
write_db -all_root_attributes ${DESIGN_TOP}_syn.db
file mkdir innovus
write_db -common -all_root_attributes innovus/${DESIGN_TOP}.db
