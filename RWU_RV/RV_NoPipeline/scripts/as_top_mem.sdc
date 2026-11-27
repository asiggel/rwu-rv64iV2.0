#===============================================================================
# as_top_mem.sdc -- timing constraints common to all modes, RV_NoPipeline
#
# Constraint modes (xh018_mmmc.tcl) = this file + one mode file:
#   func      as_top_mem_func.sdc   CPU runs, I-Mem clocked by clk_div_s
#   jtag_load as_top_mem_jtag.sdc   JTAG loads the I-Mem, macro clocked by tck_i
#
# Operating point (spec, Section "Clock Concept", tab:asNoPipelineClk):
#   clk_i       100 MHz external
#   clk_core    clk_i / 80 = 1.25 MHz, CGU counter divider (clk_core_div = 80)
#   tck_i       <= 25 MHz JTAG, asynchronous to clk_i
#
# Design top: cc_chip_top (pad ring); the ports are the bond pads and carry
# the as_top_mem port names. Hierarchical pin names follow src/cc_chip_top.sv,
# src/asTopMem.sv and ip_cgu/src/asCguTop.sv (instances core, core/cgu/CGUCore,
# core/as_jtag). Keep those hierarchies ungrouped until after synthesis, or
# update the names here.
#===============================================================================

# ---- Clocks ------------------------------------------------------------------
create_clock -name clk_i -period 10.000 [get_ports clk_i]
create_clock -name tck_i -period 40.000 [get_ports tck_i]

# The CGU divides clk_i by a counter; clk_core_o comes from a flip-flop.
create_generated_clock -name clk_core -source [get_ports clk_i] -divide_by 80 \
  [get_pins core/cgu/CGUCore/clk_core_o]

# Functional mode: the scan clock mux core_ckmux (cc_clk_mux2) selects
# clk_core. With JTAG SCANTEST (sc01_mode_o = 1) it selects tck_i, gated by
# scan_ckgate; that path is only used in scan test.
set_case_analysis 0 [get_pins core/as_jtag/sc01_mode_o]
# The I-Mem clock mux (core/as_jtag/im_mode_o) is fixed per mode in the mode file.

# Boundary scan (core/bscan, cc_bscan): transparent in both modes. EXTEST and
# INTEST switch the pin and core-input muxes to the TCK-clocked update
# flip-flops; that path is only used in board/boundary-scan test.
set_case_analysis 0 [get_pins core/as_jtag/bs_mode_o]
set_case_analysis 0 [get_pins core/as_jtag/bs_intest_o]

# JTAG writes the I-Mem with tck_i, the core reads it with clk_core; the
# software only runs after loading (rst_i = 1 while loading), so there is no
# functional crossing in either mode.
set_clock_groups -asynchronous -group {clk_i clk_core} -group {tck_i}

# The CGU bus side (BPI, id_reg_r) runs on clk_div_s like the other
# Wishbone slaves, so CPU accesses to the CGU stay inside clk_core.

set_clock_uncertainty -setup 0.300 [all_clocks]
set_clock_uncertainty -hold  0.100 [all_clocks]
set_clock_transition 0.200 [all_clocks]

# ---- Resets (asynchronous, active high) ----------------------------------
set_false_path -from [get_ports {rst_i trst_i}]

# ---- I/O ---------------------------------------------------------------------
# GPIO and UART pins are asynchronous to the core (UART RX is oversampled,
# GPIO polled by software); budget 20 % of the core period for the pad path.
set _core_period 800.000
set _func_in  [remove_from_collection [all_inputs] [get_ports {clk_i rst_i tck_i trst_i tms_i tdi_i}]]
set _func_out [remove_from_collection [all_outputs] [get_ports tdo_o]]
set_input_delay  -clock clk_core [expr {0.2 * $_core_period}] $_func_in
set_output_delay -clock clk_core [expr {0.2 * $_core_period}] $_func_out

# JTAG pins, relative to TCK (25 % of the TCK period).
set_input_delay  -clock tck_i 10.000 [get_ports {tms_i tdi_i}]
set_output_delay -clock tck_i 10.000 [get_ports tdo_o]

# ---- Environment: board at the bond pads ------------------------------------
# 10 pF board and probe load per output, 1 ns edges from the board drivers.
set_load 10.000 [all_outputs]
set_input_transition 1.000 [all_inputs]
