#===============================================================================
# as_top_mem_func.sdc -- constraint mode "func", RV_NoPipeline
#
# Read after as_top_mem.sdc. The CPU executes; the JTAG IR holds an
# instruction other than I_MEM, so the I-Mem macro is clocked by clk_div_s
# (= clk_core in functional mode) and read in every cycle.
#===============================================================================

set_case_analysis 0 [get_pins core/as_jtag/sc01_mode_o]
set_case_analysis 0 [get_pins core/as_jtag/im_mode_o]
