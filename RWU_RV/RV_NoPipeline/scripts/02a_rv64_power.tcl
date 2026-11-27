#===============================================================================
# 02a_rv64_power.tcl
#
# Innovus: SRAM macro placement and power grid of cc_chip_top (X-FAB XH018).
# Sourced by 02_rv64_floorplan_pnr.tcl after the pad ring, before
# place_design: the grid must exist before the standard cells are placed,
# and the macros before the grid, so that stripes and rails avoid them.
#
# Supplies (BSDL: VDD, GND, VDDO, GNDO):
#   VDD / GND     core 1.8 V: standard cells, SRAM macros, core side of the
#                 pads; core ring + vertical stripes + row rails
#   VDDO / GNDO   IO 3.3 V: only inside the pad ring, connected by abutment
#                 of the IO cells, corners and IO fillers
#
# All layer, pin and cell names come from $XFAB_PATHS (PG_PINS_*, PG_LAYER_*,
# WELLTAP_*, ENDCAP_*). Widths and pitch below are a first pass (the core
# draws a few mA at 1.25 MHz); an IR-drop analysis (Voltus) is still open.
#
# VERIFY-LAB (first run):
#   - Stylus command options (connect_global_net, add_rings, add_stripes,
#     route_special) in Innovus 26.1
#   - which metal layers the SRAM macros block: stripes over the macros
#     must not short their internal routing (verify_drc around the macros)
#   - the macro power pins are reached by route_special -connect block_pin
#===============================================================================

# ------------------------------------------------------------------------
# Parameters (um). Ring: offset + 2 x (width + spacing) must fit into
# CORE_MARGIN (02_rv64_floorplan_pnr.tcl): 3 + 2 x (12 + 3) = 33 <= 35.
# ------------------------------------------------------------------------
set PG_RING_W       12.0
set PG_RING_S        3.0
set PG_RING_OFF      3.0
set PG_STRIPE_W      8.0
set PG_STRIPE_S      3.0
set PG_STRIPE_PITCH 200.0     ;# VDD-GND pair every 200 um
set MACRO_HALO      20.0      ;# keep-out around the macros, room for rails

# ------------------------------------------------------------------------
# 1. SRAM macros: fixed in the lower corners of the core
# ------------------------------------------------------------------------
# I-Mem lower left, D-Mem lower right; if both do not fit next to each
# other, the D-Mem goes to the upper right. Sizes from the macro LEF.
set core_bbox [lindex [get_db current_design .core_bbox] 0]
lassign $core_bbox cllx clly curx cury

proc as_macro_inst {cell} {
  set insts [get_db insts -if ".base_cell.name==$cell"]
  if {[llength $insts] != 1} {
    error "AS-pnr: expected one instance of macro $cell, found [llength $insts]"
  }
  return [lindex $insts 0]
}
set imem [as_macro_inst $IMEM_MACRO]
set dmem [as_macro_inst $DMEM_MACRO]
lassign [lindex [get_db $imem .base_cell.bbox] 0] - - iw ih
lassign [lindex [get_db $dmem .base_cell.bbox] 0] - - dw dh

set ix [expr {$cllx + $MACRO_HALO}]
set iy [expr {$clly + $MACRO_HALO}]
set dx [expr {$curx - $MACRO_HALO - $dw}]
if {$ix + $iw + 2*$MACRO_HALO <= $dx} {
  set dy [expr {$clly + $MACRO_HALO}]
} else {
  set dy [expr {$cury - $MACRO_HALO - $dh}]
}
placeInstance [get_db $imem .name] [list $ix $iy] R0 -fixed
placeInstance [get_db $dmem .name] [list $dx $dy] R0 -fixed
foreach m [list $imem $dmem] {
  addHaloToBlock $MACRO_HALO $MACRO_HALO $MACRO_HALO $MACRO_HALO [get_db $m .name]
}
puts "AS-pnr: I-Mem ${iw}x${ih} at ($ix,$iy), D-Mem ${dw}x${dh} at ($dx,$dy)"

# ------------------------------------------------------------------------
# 2. Global net connections: which cell pins belong to which supply net
# ------------------------------------------------------------------------
foreach {net pins} [list VDD $PG_PINS_VDD GND $PG_PINS_GND \
                         VDDO $PG_PINS_VDDO GNDO $PG_PINS_GNDO] {
  foreach p $pins {
    connect_global_net $net -type pg_pin -pin_base_name $p -inst_base_name *
  }
}
# Constant 1/0 from synthesis (tie cells or 1'b1 / 1'b0 nets)
connect_global_net VDD -type tie_hi -inst_base_name *
connect_global_net GND -type tie_lo -inst_base_name *

# ------------------------------------------------------------------------
# 3. Well taps and end caps (only if the library needs them)
# ------------------------------------------------------------------------
if {[info exists WELLTAP_CELL] && $WELLTAP_CELL ne ""} {
  add_well_taps -cell $WELLTAP_CELL -cell_interval $WELLTAP_INTERVAL
}
if {[info exists ENDCAP_CELL] && $ENDCAP_CELL ne ""} {
  set_db add_endcaps_left_edge  $ENDCAP_CELL
  set_db add_endcaps_right_edge $ENDCAP_CELL
  add_endcaps
}

# ------------------------------------------------------------------------
# 4. Core ring VDD/GND: horizontal sides on PG_LAYER_H, vertical on PG_LAYER_V
# ------------------------------------------------------------------------
add_rings -nets {VDD GND} -type core_rings -follow core \
  -layer [list top $PG_LAYER_H bottom $PG_LAYER_H left $PG_LAYER_V right $PG_LAYER_V] \
  -width   $PG_RING_W \
  -spacing $PG_RING_S \
  -offset  $PG_RING_OFF

# ------------------------------------------------------------------------
# 5. Vertical stripes VDD/GND on the top metal, ring to ring
# ------------------------------------------------------------------------
add_stripes -nets {VDD GND} -layer $PG_LAYER_V -direction vertical \
  -width   $PG_STRIPE_W \
  -spacing $PG_STRIPE_S \
  -set_to_set_distance $PG_STRIPE_PITCH \
  -start_offset [expr {$PG_STRIPE_PITCH / 2}]

# ------------------------------------------------------------------------
# 6. Special routes: row rails (followpins), supply pads to the ring,
#    macro power pins to ring/stripes
# ------------------------------------------------------------------------
route_special -nets {VDD GND} -connect {core_pin pad_pin block_pin}

verify_connectivity -net {VDD GND} -type special > ${DESIGN_TOP}_pg_connectivity.rpt
