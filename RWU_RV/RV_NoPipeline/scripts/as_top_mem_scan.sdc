#===============================================================================
# as_top_mem_scan.sdc -- constraint mode "scan", RV_NoPipeline
#
# Read after as_top_mem.sdc, only by the sign-off STA (xh018_mmmc_sta.tcl).
# Genus and Innovus do not optimize for it: in SCANTEST the core runs on
# tck_i, and a 40 ns capture budget for the functional logic would make
# Genus upsize paths that only need 800 ns in operation.
#
# JTAG SCANTEST (IR = 129): core_ckmux selects tck_i, gated by scan_ckgate in
# Capture-DR and Shift-DR. All scan flip-flops are clocked by tck_i (posedge),
# the TAP by its negedge. The analysis covers
#   shift    scan flip-flop -> scan flip-flop, TAP sc01_tdi_o -> first FF,
#            last FF -> sc01_tdo_i -> TDO register (negedge)
#   capture  functional logic between the scan flip-flops at TCK speed
# Hold in shift is the critical check: the scan chain has no logic between
# the flip-flops, and the clock tree skew alone can break it.
#
# Setup violations in capture only limit the TCK frequency of SCANTEST; the
# tester can shift at 25 MHz and capture slower. Hold violations must be zero.
# GPIO/UART pins: no tester timing yet (ATPG not set up), so the pin paths
# keep their clk_core budgets from as_top_mem.sdc and are asynchronous to
# tck_i here.
#===============================================================================

set_case_analysis 1 [get_pins core/as_jtag/sc01_mode_o]
set_case_analysis 0 [get_pins core/as_jtag/im_mode_o]
