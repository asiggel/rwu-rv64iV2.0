#!/bin/bash
#===============================================================================
# sta.sh -- sign-off static timing analysis of RV_NoPipeline (cc_chip_top,
#           X-FAB XH018) with Cadence Tempus
#
# Usage:
#   ./scripts/sta/sta.sh [options]
#
# Options:
#   -b, --batch     run the analysis, print the worst slack per view, exit
#                   (default: the Tempus shell stays open after the analysis
#                   for your own report_timing queries; leave with 'exit')
#   --no-si         without crosstalk delay (SI); default: with SI
#   -c, --clean     delete build_sta/ before starting
#   -h, --help      show this help
#
# Steps:
#   1. inputs: routed netlist build_innovus/cc_chip_top_routed.v, SPEF per
#      RC corner build_quantus/cc_chip_top_rc_{max,typ,min}.spef
#   2. Tempus runs ../03b_rv64_sta.tcl: MMMC xh018_mmmc_sta.tcl (modes func,
#      jtag_load, scan), OCV + CPPR, reports, SDF
#   3. batch: worst setup/hold slack per view, violation count, SDF present
#
# Run ./scripts/quantus/quantus_rcx.sh first. All results go to build_sta/
# (never in git: reports and SDF hold X-FAB cell names).
# Then: post-route gate-level simulation with the Tempus SDF:
#   ./scripts/gatesim/gatesim.sh -r -p -s
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA): Liberty files of the corners
#
# Exit code: 0 = no setup/hold violation, 1 = violation / Tempus error /
#            missing output, 2 = usage / environment error
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_sta}"
INNOVUS_ROOT="${INNOVUS_ROOT:-$PROJECT_ROOT/build_innovus}"
QUANTUS_ROOT="${QUANTUS_ROOT:-$PROJECT_ROOT/build_quantus}"
DESIGN_TOP=cc_chip_top

MODE="shell"
SI=1
CLEAN=0

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--batch) MODE="batch" ;;
    --no-si)    SI=0 ;;
    -c|--clean) CLEAN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! command -v tempus >/dev/null 2>&1; then
  echo "ERROR: 'tempus' not in PATH (Cadence environment loaded?)" >&2
  exit 2
fi
if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi

# ------------------------------------------------------------------------
# 1. Inputs
# ------------------------------------------------------------------------
NETLIST="$INNOVUS_ROOT/${DESIGN_TOP}_routed.v"
if [ ! -s "$NETLIST" ]; then
  echo "ERROR: $NETLIST not found -- run ./scripts/quantus/quantus_rcx.sh first" >&2
  echo "       (it writes the netlist from cc_chip_top_final.db if needed)" >&2
  exit 2
fi
for c in rc_max rc_typ rc_min; do
  if [ ! -s "$QUANTUS_ROOT/${DESIGN_TOP}_$c.spef" ]; then
    echo "ERROR: $QUANTUS_ROOT/${DESIGN_TOP}_$c.spef not found -- run ./scripts/quantus/quantus_rcx.sh" >&2
    exit 2
  fi
done

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT" || exit 2
rm -f sta_*.rpt sta_summary.txt ./*.sdf

# ------------------------------------------------------------------------
# 2. Tempus
# ------------------------------------------------------------------------
{
  echo "set NETLIST  $NETLIST"
  echo "set SPEF_DIR $QUANTUS_ROOT"
  echo "set SI       $SI"
  echo "source $TCL_DIR/03b_rv64_sta.tcl"
  [ "$MODE" = "batch" ] && echo "exit"
} > run.tcl

echo "=== [tempus] 1/2 03b_rv64_sta.tcl ($MODE, SI=$SI) in $BUILD_ROOT"
if [ "$MODE" = "shell" ]; then
  echo "    the Tempus shell stays open after the analysis; leave with 'exit'"
  tempus -stylus -files run.tcl -log sta
  echo "=== [tempus] shell closed, reports in $BUILD_ROOT"
  exit 0
fi
tempus -stylus -files run.tcl -log sta < /dev/null > /dev/null 2>&1
LOG="$(ls -t sta.log* 2>/dev/null | head -1)"

# ------------------------------------------------------------------------
# 3. Evaluate (batch)
# ------------------------------------------------------------------------
echo "=== [tempus] 2/2 result"
RC=0
if [ -n "$LOG" ] && grep -q '^\*\*ERROR' "$LOG"; then
  grep '^\*\*ERROR' "$LOG" | head -10
  RC=1
fi
if [ -s sta_summary.txt ]; then
  echo "  check view            worst slack [ns]"
  while read -r check view slack; do
    flag=""
    case "$slack" in
      n/a) flag="  (see sta_${check}_${view}.rpt)" ;;
      -*)  flag="  VIOLATED"; RC=1 ;;
    esac
    printf '  %-5s %-15s %s%s\n' "$check" "$view" "$slack" "$flag"
  done < sta_summary.txt
else
  echo "  sta_summary.txt missing"
  RC=1
fi
nviol="$(grep -ciE 'VIOLATED' sta_violators.rpt 2>/dev/null)"
echo "  violators (timing + DRV): ${nviol:-?} line(s) in sta_violators.rpt"
for f in "${DESIGN_TOP}_sta_func.sdf" "${DESIGN_TOP}_sta_scan.sdf"; do
  if [ -s "$f" ]; then echo "  SDF: $f"; else echo "  SDF: $f missing"; RC=1; fi
done
echo "--- reports: $BUILD_ROOT/sta_*.rpt, log: $BUILD_ROOT/${LOG:-sta.log}"

if [ $RC -eq 0 ]; then
  echo "PASS  sign-off STA of $DESIGN_TOP, next: ./scripts/gatesim/gatesim.sh -r -p -s"
else
  echo "FAIL  sign-off STA of $DESIGN_TOP (violations or errors, see the reports)"
fi
exit $RC
