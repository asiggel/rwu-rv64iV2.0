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
# 00_rv64_elab.tcl and xh018_mmmc.tcl only use the variables below.
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

# SPRAM macro cell names (I-Mem 8192x32, D-Mem 1024x64 with bit write mask)
set IMEM_MACRO <imem_macro_name>
set DMEM_MACRO <dmem_macro_name>
