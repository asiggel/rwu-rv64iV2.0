#===============================================================================
# as_top_mem_jtag.sdc -- constraint mode "jtag_load", RV_NoPipeline
#
# Read after as_top_mem.sdc. JTAG loads the program (spec, I-Mem load
# procedure): the IR holds I_MEM, the I-Mem macro is clocked by tck_i, and
# rst_i = 1 keeps the CPU and the CGU counter still.
#
# Paths this mode adds to the analysis, all in the tck_i domain:
#   I-Mem DR (dr_reg imem_load, posedge) -> macro D / A      full TCK period
#   im_upd_del_s (posedge) -> wr_i -> macro CEn / WEn / A   full TCK period
#   TAP control (negedge) -> DR cells (posedge)             half TCK period
# The macro Q output goes to the core (clk_core), asynchronous by the clock
# groups in as_top_mem.sdc; the core is in reset during loading.
#===============================================================================

set_case_analysis 0 [get_pins core/as_jtag/sc01_mode_o]
set_case_analysis 1 [get_pins core/as_jtag/im_mode_o]
