#!/bin/bash
#===============================================================================
# genus_syn.sh -- logic synthesis of RV_NoPipeline (cc_chip_top, X-FAB XH018)
#                 with Cadence Genus
#
# Usage:
#   ./scripts/genus/genus_syn.sh [options]
#
# Options:
#   -b, --batch     no GUI: elaborate + synthesize, write reports and outputs,
#                   print a summary, exit (default: GUI)
#   -e, --elab      elaborate only. With GUI: Genus opens with the elaborated
#                   design loaded, and you run syn_generic / syn_map / syn_opt
#                   yourself in the Genus console.
#   -c, --clean     delete build_genus/ before starting
#   -h, --help      show this help
#
# Steps:
#   1. elaborate   ../00_rv64_elab.tcl  (always batch)  -> cc_chip_top_elab.db
#   2. synthesize  ../01b_rv64_syn.tcl  (batch or GUI)  -> netlist, SDC, SDF,
#                                                         reports, Innovus DB
#   3. evaluate    Genus errors, unresolved cells, outputs present, timing,
#                  scan chain
#
# All results go to build_genus/ (logs, reports, netlist, innovus/).
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA, never in git; template:
#                scripts/xh018_paths_template.tcl)
#
# Exit code: 0 = synthesis ok, 1 = Genus error / missing output,
#            2 = usage / environment error
#
# Single source of truth: the RTL file list and defines, libraries, MMMC and
# SDC live in ../rv64_rtl_setup.tcl, ../00_rv64_elab.tcl, ../xh018_mmmc.tcl
# and ../as_top_mem*.sdc. This script
# only calls them, so it never has to be edited when the design changes.
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_genus}"
DESIGN_TOP=cc_chip_top

MODE="gui"
ELAB_ONLY=0
CLEAN=0

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--batch) MODE="batch" ;;
    -e|--elab)  ELAB_ONLY=1 ;;
    -c|--clean) CLEAN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! command -v genus >/dev/null 2>&1; then
  echo "ERROR: 'genus' not in PATH (Cadence environment loaded?)" >&2
  exit 2
fi
if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi
if [ "$MODE" = "gui" ] && [ -z "${DISPLAY:-}" ]; then
  echo "ERROR: no X display for the GUI (ssh -X?) -- or use --batch" >&2
  exit 2
fi

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT" || exit 2

# Genus messages start with "Error   :" in column 0.
genus_errors() { grep -E '^Error *:' "$1" 2>/dev/null | head -10; }

# Genus keeps reading commands from stdin after the -files scripts. Each
# batch script therefore ends with "exit", and stdin is /dev/null so that a
# script aborted by an error cannot leave Genus waiting at its prompt.
run_genus_batch() {
  local name="$1"
  genus -files "$name.tcl" -log "$name" -overwrite < /dev/null > /dev/null 2>&1
}

# ------------------------------------------------------------------------
# 1. Elaborate (always batch, takes little time)
# ------------------------------------------------------------------------
cat > elab.tcl <<EOF
source $TCL_DIR/00_rv64_elab.tcl
exit
EOF

echo "=== [genus] 1/3 elaborate $DESIGN_TOP in $BUILD_ROOT"
rm -f "${DESIGN_TOP}_elab.db"
run_genus_batch elab
if [ -n "$(genus_errors elab.log)" ] || [ ! -e "${DESIGN_TOP}_elab.db" ]; then
  genus_errors elab.log
  echo "FAIL  elaboration (see $BUILD_ROOT/elab.log)"
  exit 1
fi

# ------------------------------------------------------------------------
# 2. Synthesize
# ------------------------------------------------------------------------
if [ "$MODE" = "gui" ]; then
  if [ "$ELAB_ONLY" -eq 1 ]; then
    cat > syn_gui.tcl <<EOF
read_db ${DESIGN_TOP}_elab.db
gui_show
puts "Elaborated design loaded. Next: syn_generic, syn_map, syn_opt"
EOF
  else
    cat > syn_gui.tcl <<EOF
source $TCL_DIR/01b_rv64_syn.tcl
gui_show
EOF
  fi
  echo "=== [genus] 2/3 Genus GUI (close it with 'exit' in the console)"
  genus -files syn_gui.tcl -log syn_gui -overwrite
  echo "=== [genus] GUI closed, log: $BUILD_ROOT/syn_gui.log"
  exit 0
fi

if [ "$ELAB_ONLY" -eq 1 ]; then
  echo "=== [genus] elaboration only, log: $BUILD_ROOT/elab.log"
  grep -iE 'unresolved' elab.log | head -5
  echo "PASS  elaboration"
  exit 0
fi

cat > syn.tcl <<EOF
source $TCL_DIR/01b_rv64_syn.tcl
exit
EOF

echo "=== [genus] 2/3 synthesize (batch), log: $BUILD_ROOT/syn.log"
rm -f "${DESIGN_TOP}_syn.v"
run_genus_batch syn

# ------------------------------------------------------------------------
# 3. Evaluate
# ------------------------------------------------------------------------
echo "=== [genus] 3/3 result"
RC=0
if [ -n "$(genus_errors syn.log)" ]; then
  genus_errors syn.log
  RC=1
fi
for f in "${DESIGN_TOP}_syn.v" "${DESIGN_TOP}_syn.sdc" "${DESIGN_TOP}_syn_jtag.sdc" \
         "${DESIGN_TOP}_syn.sdf" "${DESIGN_TOP}_syn.scandef" "innovus/${DESIGN_TOP}.db"; do
  if [ ! -e "$f" ]; then
    echo "missing output: $f"
    RC=1
  fi
done
if grep -qiE 'unresolved.*[1-9]' "${DESIGN_TOP}_check.rpt" 2>/dev/null; then
  grep -iE 'unresolved' "${DESIGN_TOP}_check.rpt" | head -5
  RC=1
fi

echo "--- worst slack per setup view (negative = timing violated)"
for view in av_slow av_typ av_jtag_slow; do
  slack="$(grep -iE 'slack' "${DESIGN_TOP}_timing_${view}.rpt" 2>/dev/null \
           | head -1 | sed 's/^ *//')"
  printf '  %-13s %s\n' "$view" "${slack:-no slack line found}"
done
echo "--- scan chain sc01 (length = +SCAN_LENGTH for the gate-level scan test)"
if [ -s "${DESIGN_TOP}_scan_chains.rpt" ]; then
  grep -iE 'sc01|length' "${DESIGN_TOP}_scan_chains.rpt" | head -5 | sed 's/^/  /'
else
  echo "  no ${DESIGN_TOP}_scan_chains.rpt"
  RC=1
fi
echo "--- reports: $BUILD_ROOT/${DESIGN_TOP}_{area,qor,timing_*,scan_chains,dft_rules*}.rpt"

if [ $RC -eq 0 ]; then
  echo "PASS  synthesis of $DESIGN_TOP"
else
  echo "FAIL  synthesis of $DESIGN_TOP (see $BUILD_ROOT/syn.log)"
fi
exit $RC
