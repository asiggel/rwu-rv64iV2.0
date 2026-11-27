#!/bin/bash
#===============================================================================
# lec.sh -- formal equivalence check of RV_NoPipeline (cc_chip_top, X-FAB
#           XH018) with Cadence Conformal LEC
#
# Usage:
#   ./scripts/lec/lec.sh [options]
#
# Options:
#   -m, --mode M    rtl2syn  RTL <-> Genus netlist (build_genus/)
#                   syn2pnr  Genus netlist <-> Innovus netlist (build_innovus/)
#                   all      both, one after the other (default)
#   -g, --genus     rtl2syn with the dofile Genus wrote (write_do_lec,
#                   build_genus/cc_chip_top_rtl2syn_genus.do) instead of
#                   ../04_rv64_lec.tcl -- fallback and cross-check
#   -i, --gui       Conformal GUI stays open after the run (one mode only),
#                   e.g. to debug a non-equivalent point in the schematic
#   -c, --clean     delete build_lec/ before starting
#   -h, --help      show this help
#
# Steps per mode:
#   1. inputs: Genus netlist (and for -g the Genus dofile; missing ->
#      written from cc_chip_top_syn.db), for syn2pnr the routed netlist
#      (missing -> ./scripts/quantus/quantus_rcx.sh writes it, or run
#      02b_rv64_export.tcl yourself)
#   2. Conformal runs ../04_rv64_lec.tcl with LEC_MODE (Tcl mode)
#   3. evaluate: equivalent / non-equivalent / abort points, unmapped
#      points, reports in build_lec/
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA): Liberty files, cell names for
#                the RTL defines
#
# Results in build_lec/ (never in git: logs and reports hold X-FAB names).
#
# Exit code: 0 = equivalent, 1 = non-equivalent / abort / tool error,
#            2 = usage / environment error
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_lec}"
GENUS_ROOT="${GENUS_ROOT:-$PROJECT_ROOT/build_genus}"
INNOVUS_ROOT="${INNOVUS_ROOT:-$PROJECT_ROOT/build_innovus}"
DESIGN_TOP=cc_chip_top

LEC_MODE="all"
GENUS_DO=0
GUI=0
CLEAN=0

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)  shift; LEC_MODE="${1:?--mode needs rtl2syn, syn2pnr or all}" ;;
    -g|--genus) GENUS_DO=1 ;;
    -i|--gui)   GUI=1 ;;
    -c|--clean) CLEAN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$LEC_MODE" in
  rtl2syn|syn2pnr) MODES="$LEC_MODE" ;;
  all)             MODES="rtl2syn syn2pnr" ;;
  *) echo "ERROR: unknown mode '$LEC_MODE' (rtl2syn | syn2pnr | all)" >&2; exit 2 ;;
esac
if [ "$GUI" -eq 1 ] && [ "$LEC_MODE" = "all" ]; then
  echo "ERROR: --gui needs one mode (-m rtl2syn or -m syn2pnr)" >&2; exit 2
fi
if [ "$GENUS_DO" -eq 1 ] && [ "$LEC_MODE" = "syn2pnr" ]; then
  echo "ERROR: --genus only applies to rtl2syn" >&2; exit 2
fi
if ! command -v lec >/dev/null 2>&1; then
  echo "ERROR: 'lec' not in PATH (Cadence Conformal environment loaded?)" >&2
  exit 2
fi
if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi
if [ "$GUI" -eq 1 ] && [ -z "${DISPLAY:-}" ]; then
  echo "ERROR: no X display for the GUI (ssh -X?)" >&2; exit 2
fi

SYN_NETLIST="$GENUS_ROOT/${DESIGN_TOP}_syn.v"
PNR_NETLIST="$INNOVUS_ROOT/${DESIGN_TOP}_routed.v"
if [ ! -s "$SYN_NETLIST" ]; then
  echo "ERROR: $SYN_NETLIST not found -- run ./scripts/genus/genus_syn.sh -b" >&2
  exit 2
fi
case " $MODES " in
  *" syn2pnr "*)
    if [ ! -s "$PNR_NETLIST" ]; then
      echo "ERROR: $PNR_NETLIST not found -- ./scripts/quantus/quantus_rcx.sh" >&2
      echo "       writes it from cc_chip_top_final.db (or ./scripts/innovus/innovus_post.sh -b)" >&2
      exit 2
    fi ;;
esac

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

# Last compare table in a log: "<class> <total>" for Equivalent,
# Non-equivalent, Abort (VERIFY-LAB: table layout of Conformal 26.1)
lec_counts() {
  awk '/Compared points/ {eq=0; ne=0; ab=0; seen=1}
       seen && /^ *Equivalent/     {eq=$NF}
       seen && /^ *Non-equivalent/ {ne=$NF}
       seen && /^ *Abort/          {ab=$NF}
       END {if (seen) print eq, ne, ab; else print "? ? ?"}' "$1"
}

RC=0
for mode in $MODES; do
  echo "=== [lec] $mode"
  if [ "$mode" = "rtl2syn" ] && [ "$GENUS_DO" -eq 1 ]; then
    # Genus dofile: relative paths, runs in build_genus/
    WORK="$GENUS_ROOT"
    DOFILE="${DESIGN_TOP}_rtl2syn_genus.do"
    if [ ! -s "$WORK/$DOFILE" ]; then
      echo "    $DOFILE missing: writing it from ${DESIGN_TOP}_syn.db"
      ( cd "$WORK" || exit 2
        printf 'read_db %s_syn.db\nwrite_do_lec -golden_design rtl -revised_design %s_syn.v -logfile lec_genus_rtl2syn.log > %s\nexit\n' \
          "$DESIGN_TOP" "$DESIGN_TOP" "$DOFILE" > write_do_lec.tcl
        genus -batch -files write_do_lec.tcl -log write_do_lec < /dev/null > /dev/null 2>&1 )
      if [ ! -s "$WORK/$DOFILE" ]; then
        echo "ERROR: Genus did not write $WORK/$DOFILE" >&2; RC=1; continue
      fi
    fi
    LOG="$WORK/lec_genus_rtl2syn.log"
    LEC_ARGS=(-xl -dofile "$DOFILE")
  else
    WORK="$BUILD_ROOT"
    {
      echo "set LEC_MODE    $mode"
      echo "set SYN_NETLIST $SYN_NETLIST"
      echo "set PNR_NETLIST $PNR_NETLIST"
      echo "source $TCL_DIR/04_rv64_lec.tcl"
      [ "$GUI" -eq 0 ] && echo "exit -force"
    } > "$WORK/run_$mode.tcl"
    LOG="$WORK/lec_$mode.log"
    LEC_ARGS=(-xl -tclmode -dofile "run_$mode.tcl")
  fi

  cd "$WORK" || exit 2
  rm -f "$LOG"
  if [ "$GUI" -eq 1 ]; then
    echo "    Conformal GUI stays open after the run; leave with 'exit'"
    lec "${LEC_ARGS[@]}"
    continue
  fi
  lec "${LEC_ARGS[@]}" -nogui < /dev/null > "lec_${mode}_stdout.txt" 2>&1

  read -r EQ NE AB <<< "$(lec_counts "$LOG" 2>/dev/null || echo '? ? ?')"
  printf '    equivalent %s, non-equivalent %s, abort %s\n' "$EQ" "$NE" "$AB"
  if grep -qE '^// *Error|^Error' "$LOG" 2>/dev/null; then
    grep -E '^// *Error|^Error' "$LOG" | head -5 | sed 's/^/    /'
  fi
  if [ "$EQ" = "?" ] || [ "$EQ" = "0" ] || [ "$NE" != "0" ] || [ "$AB" != "0" ]; then
    echo "FAIL  LEC $mode (see $LOG, ${WORK}/lec_${mode}_noneq.rpt)"
    RC=1
  else
    echo "PASS  LEC $mode"
  fi
done
exit $RC
