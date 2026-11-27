#===============================================================================
# 02b_rv64_export.tcl
#
# Innovus: write the routed design for sign-off. Sourced at the end of
# 02_rv64_floorplan_pnr.tcl; scripts/quantus/quantus_rcx.sh also runs it on
# its own on an existing cc_chip_top_routed.db (read_db first).
#
#   cc_chip_top_routed.v    netlist without physical-only cells (fillers,
#                           corners), with the CTS buffers: Tempus and the
#                           post-route gate-level simulation
#   cc_chip_top_routed.def  floorplan, netlist and routing: Quantus extracts
#                           the parasitics from it
#===============================================================================

set DESIGN_TOP cc_chip_top

write_netlist ${DESIGN_TOP}_routed.v
write_def -floorplan -netlist -routing ${DESIGN_TOP}_routed.def
