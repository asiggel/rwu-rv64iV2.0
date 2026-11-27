#!/bin/bash
#===============================================================================
# quantus_rcx.sh -- RC extraction of RV_NoPipeline (cc_chip_top, X-FAB
#                   XH018) with Cadence Quantus, after place & route
#
# Usage:
#   ./scripts/quantus/quantus_rcx.sh [options]
#
# Options:
#   -i, --innovus   extract from inside Innovus (Quantus engine, effort
#                   signoff, ../03a_rv64_rcx_innovus.tcl) instead of the
#                   standalone Quantus run (default, ../03a_rv64_quantus.tcl)
#   -c, --clean     delete build_quantus/ before starting
#   -h, --help      show this help
#
# Steps:
#   1. hand-off from Innovus: build_innovus/cc_chip_top_routed.v and .def.
#      Missing (P&R ran before 02b_rv64_export.tcl existed) but
#      cc_chip_top_routed.db present: write them now from the DB.
#   2. extraction, one SPEF per RC corner of xh018_mmmc.tcl:
#        cc_chip_top_rc_max.spef   slow corner, 125 C  (setup)
#        cc_chip_top_rc_typ.spef   typ corner,   25 C
#        cc_chip_top_rc_min.spef   fast corner, -40 C  (hold)
#   3. evaluate: errors in the log, SPEF files present, number of nets
#
# Run scripts/innovus/innovus_pnr.sh -b first. Results go to build_quantus/
# (never in git: CCL, lib.defs and SPEF hold X-FAB paths and cell names).
# Next step: ./scripts/sta/sta.sh -b
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA): LEF_FILES, QRC_MAX/_TYP/_MIN,
#                optionally QRC_LAYERMAP (template:
#                scripts/xh018_paths_template.tcl)
#
# Exit code: 0 = all three SPEF written, 1 = tool error / SPEF missing,
#            2 = usage / environment error
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_quantus}"
INNOVUS_ROOT="${INNOVUS_ROOT:-$PROJECT_ROOT/build_innovus}"
DESIGN_TOP=cc_chip_top
CORNERS="rc_max rc_typ rc_min"

ENGINE="quantus"
CLEAN=0

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--innovus) ENGINE="innovus" ;;
    -c|--clean)   CLEAN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi
for tool in innovus $( [ "$ENGINE" = "quantus" ] && echo quantus tclsh ); do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not in PATH (Cadence environment loaded?)" >&2
    exit 2
  fi
done

ROUTED_DB="$INNOVUS_ROOT/${DESIGN_TOP}_routed.db"
ROUTED_V="$INNOVUS_ROOT/${DESIGN_TOP}_routed.v"
ROUTED_DEF="$INNOVUS_ROOT/${DESIGN_TOP}_routed.def"
if [ ! -e "$ROUTED_DB" ]; then
  echo "ERROR: $ROUTED_DB not found -- run ./scripts/innovus/innovus_pnr.sh -b first" >&2
  exit 2
fi

# ------------------------------------------------------------------------
# 1. Hand-off from Innovus
# ------------------------------------------------------------------------
echo "=== [quantus] 1/3 hand-off from $INNOVUS_ROOT"
if [ ! -s "$ROUTED_V" ] || [ ! -s "$ROUTED_DEF" ] || [ "$ROUTED_DB" -nt "$ROUTED_DEF" ]; then
  echo "    writing ${DESIGN_TOP}_routed.v / .def from ${DESIGN_TOP}_routed.db"
  ( cd "$INNOVUS_ROOT" || exit 2
    printf 'read_db %s\nsource %s\nexit\n' "$(basename "$ROUTED_DB")" \
      "$TCL_DIR/02b_rv64_export.tcl" > export.tcl
    innovus -batch -files export.tcl -log export -overwrite < /dev/null > /dev/null 2>&1 )
  if [ ! -s "$ROUTED_V" ] || [ ! -s "$ROUTED_DEF" ]; then
    echo "ERROR: export failed, see $INNOVUS_ROOT/export.log" >&2
    exit 1
  fi
fi
echo "    netlist $ROUTED_V"
echo "    DEF     $ROUTED_DEF"

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT" || exit 2
rm -f ./*.spef

# ------------------------------------------------------------------------
# 2. Extraction
# ------------------------------------------------------------------------
if [ "$ENGINE" = "quantus" ]; then
  echo "=== [quantus] 2/3 standalone Quantus in $BUILD_ROOT"
  tclsh "$TCL_DIR/03a_rv64_quantus.tcl" "$ROUTED_DEF" || exit 2
  LOG="$BUILD_ROOT/quantus.log"
  quantus -cmd quantus.ccl < /dev/null > "$LOG" 2>&1
else
  echo "=== [quantus] 2/3 Quantus engine inside Innovus in $BUILD_ROOT"
  ln -sfn "$ROUTED_DB" "${DESIGN_TOP}_routed.db"
  printf 'source %s\nexit\n' "$TCL_DIR/03a_rv64_rcx_innovus.tcl" > rcx.tcl
  LOG="$BUILD_ROOT/rcx.log"
  innovus -batch -files rcx.tcl -log rcx -overwrite < /dev/null > /dev/null 2>&1
fi

# ------------------------------------------------------------------------
# 3. Evaluate
# ------------------------------------------------------------------------
echo "=== [quantus] 3/3 result"
RC=0
# Quantus: "ERROR (EXTxxx-nnn)", Innovus: "**ERROR: (IMPxxx-nnn)"
if grep -qE '^\*\*ERROR|^ *ERROR \(' "$LOG" 2>/dev/null; then
  grep -E '^\*\*ERROR|^ *ERROR \(' "$LOG" | head -10
  RC=1
fi
for c in $CORNERS; do
  f="${DESIGN_TOP}_$c.spef"
  if [ -s "$f" ]; then
    printf '  %-26s %6s nets\n' "$f" "$(grep -c '^\*D_NET' "$f")"
  else
    echo "  $f missing"
    RC=1
  fi
done
if [ $RC -ne 0 ]; then
  others="$(ls ./*.spef* 2>/dev/null | tr '\n' ' ')"
  [ -n "$others" ] && echo "  SPEF files written instead: $others (rename to ${DESIGN_TOP}_<corner>.spef)"
fi
echo "--- log: $LOG"

if [ $RC -eq 0 ]; then
  echo "PASS  RC extraction of $DESIGN_TOP ($ENGINE), next: ./scripts/sta/sta.sh -b"
else
  echo "FAIL  RC extraction of $DESIGN_TOP ($ENGINE), see $LOG"
fi
exit $RC
