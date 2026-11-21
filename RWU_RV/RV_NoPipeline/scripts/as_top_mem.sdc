#===============================================================================
# as_top_mem.sdc -- timing constraints, functional mode, RV_NoPipeline
#
# Operating point (spec, Section "Clock Concept", tab:asNoPipelineClk):
#   clk_i       100 MHz external
#   clk_core    clk_i / 80 = 1.25 MHz, CGU counter divider (clk_core_div = 80)
#   tck_i       <= 25 MHz JTAG, asynchronous to clk_i
#
# Hierarchical pin names follow src/asTopMem.sv and ip_cgu/src/asCguTop.sv
# (instances cgu/CGUCore and as_jtag). Keep those hierarchies ungrouped
# until after synthesis, or update the names here.
#===============================================================================

# ---- Clocks ------------------------------------------------------------------
create_clock -name clk_i -period 10.000 [get_ports clk_i]
create_clock -name tck_i -period 40.000 [get_ports tck_i]

# The CGU divides clk_i by a counter; clk_core_o is its decoded output.
create_generated_clock -name clk_core -source [get_ports clk_i] -divide_by 80 \
  [get_pins cgu/CGUCore/clk_core_o]

# Functional mode: the scan bypass mux (clk_div_s = dr_cap_s ? clk_i : clk_core_s)
# selects clk_core. Without this, every core path would also be timed at the
# 100 MHz clk_i, which is only used in scan test.
set_case_analysis 0 [get_pins as_jtag/dr_cap_o]
# Same for the I-Mem clock mux (im_mode = JTAG I_MEM instruction). JTAG
# loading at tck_i needs its own constraint mode (open item).
set_case_analysis 0 [get_pins as_jtag/im_mode_o]

# JTAG writes the I-Mem with tck_i, the core reads it with clk_core; the
# software only runs after loading, so there is no functional crossing.
set_clock_groups -asynchronous -group {clk_i clk_core} -group {tck_i}

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

# ---- Environment (pad ring not yet instantiated, TECH-04) ---------------
set_load 0.050 [all_outputs]
set_input_transition 0.500 [all_inputs]
