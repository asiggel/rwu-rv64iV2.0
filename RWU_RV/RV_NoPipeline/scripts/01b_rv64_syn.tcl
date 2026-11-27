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

# The clock mux and clock gate library cells (cc_clk_mux2 / cc_clk_gate,
# XFAB_CLKCELLS) must stay exactly as instantiated.
set_db [get_db hinsts {core/scan_ckgate core/core_ckmux core/imem/mem_ckmux}] .preserve true

# ------------------------------------------------------------------------
# 3. DFT setup: muxed scan, one chain accessed through JTAG SCANTEST
# ------------------------------------------------------------------------
# In SCANTEST (IR = 129) as_top_mem clocks the core with tck_i, enabled by
# the TAP in Capture-DR and Shift-DR (cc_clk_gate) and selected by
# cc_clk_mux2. Shift and capture therefore both use tck_i.
set_db dft_scan_style muxed_scan
set_db dft_prefix     DFT_
define_test_clock -name tck_scan -period 40000 tck_i

# The test signals are TAP outputs, not pads. For the DFT rule check they are
# held at the values they have during a scan operation.
define_test_mode    -name scan_mode  -active high core/as_jtag/sc01_mode_o
define_test_mode    -name scan_clken -active high core/as_jtag/sc01_clock_o
define_test_mode    -name rst_off    -active low  rst_i
define_test_mode    -name trst_off   -active high trst_i
define_shift_enable -name scan_shift -active high core/as_jtag/sc01_shift_o

# Not scanned: the TAP, the boundary-scan register and the I-Mem load
# register belong to the JTAG test logic (tck_i, outside SCANTEST), the CGU
# dividers run on clk_i.
set_db [get_db hinsts core/as_jtag]     .dft_dont_scan true
set_db [get_db hinsts core/bscan]       .dft_dont_scan true
set_db [get_db hinsts core/imem_load]   .dft_dont_scan true
set_db [get_db hinsts core/cgu/CGUCore] .dft_dont_scan true

check_dft_rules > ${DESIGN_TOP}_dft_rules.rpt

# ------------------------------------------------------------------------
# 4. Run synthesis, insert the scan chain
# ------------------------------------------------------------------------
# as_imem / as_dmem_core instantiate the SPRAM macros (XFAB_SPRAM, see
# 00_rv64_elab.tcl); check_design -unresolved must report none.
# syn_map maps every DFT-compliant flip-flop to a scan flip-flop.
syn_generic
syn_map

# The chain replaces the RTL short sc01_tdi -> sc01_tdo (as_top_mem,
# XFAB_DFT): scan in at the TAP output sc01_tdi_o (= TDI in SCANTEST), scan
# out at the TAP input sc01_tdo_i (-> TDO).
define_scan_chain -name sc01 -sdi tdi_i -sdo tdo_o -shared_output \
                  -hookup_pin_sdi core/as_jtag/sc01_tdi_o \
                  -hookup_pin_sdo core/as_jtag/sc01_tdo_i
connect_scan_chains -chains sc01

syn_opt

# ------------------------------------------------------------------------
# 5. Reports (setup views: slow, typ, jtag_slow; hold views: fast, jtag_fast)
# ------------------------------------------------------------------------
check_design -unresolved          > ${DESIGN_TOP}_check.rpt
check_timing_intent               > ${DESIGN_TOP}_timing_intent.rpt
report_area                       > ${DESIGN_TOP}_area.rpt
report_gates                      > ${DESIGN_TOP}_gates.rpt
report_clocks                     > ${DESIGN_TOP}_clocks.rpt
report_qor                        > ${DESIGN_TOP}_qor.rpt
report_power                      > ${DESIGN_TOP}_power.rpt
report_scan_chains                > ${DESIGN_TOP}_scan_chains.rpt
check_dft_rules                   > ${DESIGN_TOP}_dft_rules_final.rpt
foreach view {av_slow av_typ av_jtag_slow} {
  report_timing -views $view -max_paths 20 > ${DESIGN_TOP}_timing_${view}.rpt
}

# ------------------------------------------------------------------------
# 6. Outputs: netlist + constraints for Innovus, gate-level simulation, LEC
# ------------------------------------------------------------------------
write_hdl                  > ${DESIGN_TOP}_syn.v
write_sdc -view av_slow    > ${DESIGN_TOP}_syn.sdc
write_sdc -view av_jtag_slow > ${DESIGN_TOP}_syn_jtag.sdc
write_sdf -view av_slow    > ${DESIGN_TOP}_syn.sdf
write_scandef              > ${DESIGN_TOP}_syn.scandef
# Genus's own Conformal LEC dofile (RTL -> netlist), the fallback of
# scripts/lec/lec.sh -g; the main LEC run is 04_rv64_lec.tcl
write_do_lec -golden_design rtl -revised_design ${DESIGN_TOP}_syn.v \
             -logfile lec_genus_rtl2syn.log > ${DESIGN_TOP}_rtl2syn_genus.do
write_db -all_root_attributes ${DESIGN_TOP}_syn.db
file mkdir innovus
write_db -common -all_root_attributes innovus/${DESIGN_TOP}.db
