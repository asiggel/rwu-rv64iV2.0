#===============================================================================
# xh018_paths_template.tcl
#
# Template for the local X-FAB XH018 path file. The real file holds X-FAB
# file names and directory structure, which are covered by the X-FAB NDA:
# keep it OUTSIDE this repository and point $XFAB_PATHS at it, e.g.
#
#   setenv XFAB_PATHS /path/to/X-FAB/xh018_paths.tcl     (csh)
#   export XFAB_PATHS=/path/to/X-FAB/xh018_paths.tcl     (bash)
#
# The scripts in scripts/ only use the variables below.
#
# Process variant for Variant A: 4 metal layers (MET1..MET3 + top metal),
# module LPMOS -- must match the SPRAM macros.
# Corners (common to standard cells, I/O cells and SPRAM macros):
#   slow 1.62 V / 125 C (setup), typ 1.80 V / 25 C, fast 1.98 V / -40 C (hold)
#===============================================================================

# Liberty files per corner: standard cells, I/O cells, I-Mem macro, D-Mem macro
set LIBS_SLOW [list <std_slow.lib> <io_slow.lib> <imem_slow.lib> <dmem_slow.lib>]
set LIBS_TYP  [list <std_typ.lib>  <io_typ.lib>  <imem_typ.lib>  <dmem_typ.lib>]
set LIBS_FAST [list <std_fast.lib> <io_fast.lib> <imem_fast.lib> <dmem_fast.lib>]

# LEF: technology LEF first (4-metal stack, HD site), then cells and macros
set LEF_FILES [list <tech.lef> <std_cells.lef> <io_cells.lef> <imem.lef> <dmem.lef>]

# RC: capacitance tables and QRC tech files (max / typ / min)
set CAPTBL_MAX <max.capTbl>
set CAPTBL_TYP <typ.capTbl>
set CAPTBL_MIN <min.capTbl>
set QRC_MAX    <QRC-Max/qrcTechFile>
set QRC_TYP    <QRC-Typ/qrcTechFile>
set QRC_MIN    <QRC-Min/qrcTechFile>
# Standalone Quantus (03a_rv64_quantus.tcl) only: pairs "LEF layer" "QRC
# layer" when the names in the technology LEF and the qrcTechFile differ;
# empty when they match (Innovus maps them itself)
set QRC_LAYERMAP [list]

# SPRAM macro cell names (I-Mem 8192x32, D-Mem 1024x64 with bit write mask)
set IMEM_MACRO <imem_macro_name>
set DMEM_MACRO <dmem_macro_name>

# IO_CELLS_3V cell names for the pad ring (cc_pad_*, cc_chip_top)
set PAD_IN    <cmos_input_cell>          ;# pins PAD Y PI PO
set PAD_IN_ST <schmitt_input_cell>       ;# pins PAD Y PI PO
set PAD_OUT   <tristate_output_cell>     ;# pins A EN PAD, EN active low
set PAD_BIDIR <bidirectional_cell>       ;# pins A EN PAD Y PI PO, EN active low
set PAD_VDD   <core_supply_pad>
set PAD_GND   <core_ground_pad>
set PAD_VDDO  <io_supply_pad>
set PAD_GNDO  <io_ground_pad>

# D_CELLS_HD clock cells for cc_clk_mux2 / cc_clk_gate (ip_clkcells), with
# their pin names: the RTL instantiates them by these names
set CLKMUX     <clock_mux2_cell>            ;# 2:1 clock multiplexer
set CLKMUX_I0  <pin_input_sel0>
set CLKMUX_I1  <pin_input_sel1>
set CLKMUX_S   <pin_select>
set CLKMUX_Q   <pin_output>
set ICG        <integrated_clock_gate_cell> ;# latch + AND, enable + test enable
set ICG_CK     <pin_clock>
set ICG_E      <pin_enable>
set ICG_TE     <pin_test_enable>
set ICG_Q      <pin_gated_clock>

# Physical-only cells and the standard-cell site for Innovus
# (02_rv64_floorplan_pnr.tcl, fillers after routing)
set CORE_SITE   <std_cell_site>              ;# row site of the HD standard cells
set PAD_CORNER  <io_corner_cell>
set PAD_FILLERS [list <io_filler_widest> ... <io_filler_narrowest>]  ;# widest first
set CORE_FILLERS [list <core_filler_widest> ... <core_filler_narrowest>] ;# D_CELLS_HD fillers, widest first

# Power grid (02a_rv64_power.tcl). Supply pin names of ALL cells per net:
# standard cells, IO cells (core side and IO side), SPRAM macros
set PG_PINS_VDD  [list <std_power_pin> <io_core_power_pin> <sram_power_pin>]
set PG_PINS_GND  [list <std_ground_pin> <io_core_ground_pin> <sram_ground_pin>]
set PG_PINS_VDDO [list <io_io_power_pin>]
set PG_PINS_GNDO [list <io_io_ground_pin>]
set PG_LAYER_H   <metal_for_horizontal_ring>  ;# e.g. the third metal
set PG_LAYER_V   <top_metal>                  ;# vertical ring sides + stripes
# Well taps / end caps: only if the library needs them, otherwise empty
set WELLTAP_CELL     ""
set WELLTAP_INTERVAL 50.0                     ;# um, from the design rules
set ENDCAP_CELL      ""

# Merged GDS (02c_rv64_gds.tcl): Innovus stream layer map of the PDK and
# the GDS of standard cells, IO cells, I-Mem macro, D-Mem macro
set STREAM_MAP <innovus_stream_out.map>
set GDS_FILES  [list <D_CELLS_HD.gds> <IO_CELLS_3V.gds> <imem.gds> <dmem.gds>]
set GDS_UNIT   1000                           ;# database units per um

# Verilog simulation models for the gate-level simulation (scripts/gatesim):
# standard cells, I/O cells, I-Mem macro, D-Mem macro. Plain file paths, no
# Tcl expressions: gatesim.sh also reads this file without tclsh.
set VLOG_MODELS  [list <D_CELLS_HD.v> <IO_CELLS_3V.v> <imem_macro.v> <dmem_macro.v>]
# Defines the cell models need (e.g. functional model, no notifier); may be empty
set VLOG_DEFINES [list]
