#===============================================================================
# 03a_rv64_rcx_innovus.tcl
#
# Alternative to 03a_rv64_quantus.tcl: RC extraction from inside Innovus.
# With effort level signoff Innovus runs the Quantus engine itself, with the
# QRC files of the RC corners in xh018_mmmc.tcl; no CCL, no lib.defs, no
# layer map. Use it when the standalone run does not work yet, or to compare.
#
# Writes one SPEF per RC corner into the run directory, with the same names
# as the standalone run: cc_chip_top_rc_max.spef, _rc_typ.spef, _rc_min.spef.
#
# Usage (normally: scripts/quantus/quantus_rcx.sh --innovus), in a directory
# that holds cc_chip_top_final.db (02d_rv64_postroute.tcl):
#   innovus -batch -files 03a_rv64_rcx_innovus.tcl
#===============================================================================

set DESIGN_TOP cc_chip_top

read_db ${DESIGN_TOP}_final.db

set_db extract_rc_engine       post_route
set_db extract_rc_effort_level signoff
set_db extract_rc_coupled      true

extract_rc

foreach rc {rc_max rc_typ rc_min} {
  write_parasitics -rc_corner $rc -spef_file ${DESIGN_TOP}_${rc}.spef
}
