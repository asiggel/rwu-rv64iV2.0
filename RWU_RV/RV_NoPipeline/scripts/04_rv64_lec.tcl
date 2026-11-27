#===============================================================================
# 04_rv64_lec.tcl
#
# Conformal LEC (Tcl mode): formal equivalence check of cc_chip_top
# (X-FAB XH018). Proves that synthesis and place & route did not change the
# logic function -- for all input sequences, without a testbench.
#
#   LEC_MODE rtl2syn   golden = RTL (rv64_rtl_setup.tcl, same defines as
#                      Genus), revised = Genus netlist cc_chip_top_syn.v
#   LEC_MODE syn2pnr   golden = Genus netlist, revised = Innovus netlist
#                      cc_chip_top_routed.v (CTS buffers, resizing, hold fix)
#
# Inputs (set before sourcing, normally by scripts/lec/lec.sh):
#   LEC_MODE, SYN_NETLIST, PNR_NETLIST
#   XFAB_PATHS (environment): Liberty files (typ corner) and the cell names
#                             for the RTL defines
#
# DFT: the netlist contains the scan chain, the RTL does not. In functional
# mode the scan multiplexers are transparent, so the comparison holds the
# scan test signals at their functional value:
#   core/as_jtag/sc01_shift_o   shift enable of all scan flip-flops -> 0
#   core/as_jtag/sc01_tdo_i     end of the chain (RTL: constant 0 with
#                               XFAB_DFT) -> cut in both designs, a free
#                               input, so TDO compares the TAP logic only
# The scan path itself is covered by the gate-level simulation ('scan') and
# later by ATPG, not by LEC.
#
# SPRAM macros: Liberty without a function -> black boxes, mapped by
# instance name; their pins are compared.
#
# Usage: scripts/lec/lec.sh (see its --help), or
#   lec -xl -nogui -tclmode -dofile run.tcl   (run.tcl sets the inputs and
#                                              sources this file)
#===============================================================================

set DESIGN_TOP cc_chip_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set DESIGN_PATH [file normalize $SCRIPT_DIR/../../..]

if {![info exists ::env(XFAB_PATHS)] || ![file readable $::env(XFAB_PATHS)]} {
  error "XFAB_PATHS must point to the local X-FAB path file (see $SCRIPT_DIR/xh018_paths_template.tcl)"
}
source $::env(XFAB_PATHS)
source $SCRIPT_DIR/rv64_rtl_setup.tcl

if {![info exists LEC_MODE]} { set LEC_MODE rtl2syn }

set_log_file lec_${LEC_MODE}.log -replace

# ------------------------------------------------------------------------
# 1. Libraries: same cells on both sides
# ------------------------------------------------------------------------
read_library -both -liberty $LIBS_TYP

# ------------------------------------------------------------------------
# 2. Golden and revised design
# ------------------------------------------------------------------------
switch $LEC_MODE {
  rtl2syn {
    set defs {}
    foreach d $RTL_DEFINES { lappend defs -define $d }
    read_design -golden -sv09 {*}$defs {*}$RTL_FILES
    read_design -revised -verilog $SYN_NETLIST
  }
  syn2pnr {
    read_design -golden  -verilog $SYN_NETLIST
    read_design -revised -verilog $PNR_NETLIST
  }
  default { error "LEC_MODE must be rtl2syn or syn2pnr, not '$LEC_MODE'" }
}
set_root_module $DESIGN_TOP -golden
set_root_module $DESIGN_TOP -revised

report_design_data > lec_${LEC_MODE}_design.rpt

# ------------------------------------------------------------------------
# 3. Functional mode: scan test signals held (see header)
# ------------------------------------------------------------------------
add_primary_input core/as_jtag/sc01_shift_o -pin -cut -both
add_pin_constraints 0 core/as_jtag/sc01_shift_o -both
add_primary_input core/as_jtag/sc01_tdo_i   -pin -cut -both

# Genus removes flip-flops that hold a constant and the RTL keeps them;
# both sides treat them as the constant.
set_flatten_model -seq_constant -seq_constant_x_to 0
set_flatten_model -gated_clock

# ------------------------------------------------------------------------
# 4. Map key points (flip-flops, latches, black boxes, outputs), compare
# ------------------------------------------------------------------------
set_analyze_option -auto
set_system_mode lec

report_unmapped_points -summary  > lec_${LEC_MODE}_unmapped.rpt
report_unmapped_points -notmapped >> lec_${LEC_MODE}_unmapped.rpt

add_compared_points -all
compare

# Aborts: the solver gave up on a hard cone (large multipliers, deep
# arithmetic); analyze_abort tries harder before they are reported.
analyze_abort -compare

report_verification              > lec_${LEC_MODE}_verification.rpt
report_compare_data -class nonequivalent -class abort \
                                 > lec_${LEC_MODE}_noneq.rpt
report_statistics                > lec_${LEC_MODE}_statistics.rpt
