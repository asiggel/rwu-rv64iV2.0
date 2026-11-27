#!/bin/bash
#===============================================================================
# innovus_pnr.sh -- place & route of RV_NoPipeline (cc_chip_top, X-FAB XH018)
#                   with Cadence Innovus
#
# Usage:
#   ./scripts/innovus/innovus_pnr.sh [options]
#
# Options:
#   -b, --batch       no GUI: run the flow, check DRC/antenna/connectivity,
#                     print a summary, exit (default: GUI, the window stays
#                     open after the flow)
#   -s, --stop STAGE  stop after STAGE: fp | place | cts | route | gds (default)
#                       fp     floorplan, pad ring, SRAM macros, power grid
#                       place  standard cells placed
#                       cts    clock tree built
#                       route  all wires routed, core fillers, netlists
#                       gds    merged GDS for DRC/LVS
#   -o, --open STAGE  do not run anything: open the checkpoint of STAGE in
#                     the GUI (needs an earlier run up to that stage)
#   -c, --clean       delete build_innovus/ before starting
#   -h, --help        show this help
#
# Steps:
#   1. link the Genus hand-off build_genus/innovus/cc_chip_top.db
#   2. run ../02_rv64_floorplan_pnr.tcl up to STAGE (batch or GUI)
#   3. after routing: DRC, antenna check, connectivity -> reports
#   4. batch: evaluate errors, checkpoints, timing, violation counts,
#      hand-off cc_chip_top_routed.v / .def / _lvs.v (scripts/quantus,
#      scripts/sta, LVS), with gds: cc_chip_top.gds
#
# Run scripts/genus/genus_syn.sh first. All results go to build_innovus/.
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA, never in git); the flow takes
#                the pad, corner, filler and macro cell names, the supply
#                pins and layers of the power grid and the GDS files from it
#
# Exit code: 0 = flow ran through, 1 = Innovus error / missing checkpoint,
#            2 = usage / environment error
#
# Single source of truth: floorplan, pad ring and the P&R steps live in
# ../02_rv64_floorplan_pnr.tcl. This script only calls it.
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_innovus}"
GENUS_ROOT="${GENUS_ROOT:-$PROJECT_ROOT/build_genus}"
DESIGN_TOP=cc_chip_top

MODE="gui"
STAGE="gds"
OPEN_STAGE=""
CLEAN=0

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

# Checkpoint written by 02_rv64_floorplan_pnr.tcl after each stage
checkpoint() {
  case "$1" in
    fp)    echo "${DESIGN_TOP}_fp.db" ;;
    place) echo "${DESIGN_TOP}_placed.db" ;;
    cts)   echo "${DESIGN_TOP}_cts.db" ;;
    route) echo "${DESIGN_TOP}_routed.db" ;;
    gds)   echo "${DESIGN_TOP}_routed.db" ;;
    *)     return 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--batch) MODE="batch" ;;
    -s|--stop)  shift; STAGE="${1:?--stop needs a stage}" ;;
    -o|--open)  shift; OPEN_STAGE="${1:?--open needs a stage}" ;;
    -c|--clean) CLEAN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! checkpoint "$STAGE" >/dev/null; then
  echo "ERROR: unknown stage '$STAGE' (fp | place | cts | route | gds)" >&2; exit 2
fi
if [ -n "$OPEN_STAGE" ]; then
  if ! checkpoint "$OPEN_STAGE" >/dev/null; then
    echo "ERROR: unknown stage '$OPEN_STAGE' (fp | place | cts | route | gds)" >&2; exit 2
  fi
  if [ "$MODE" = "batch" ] || [ "$CLEAN" -eq 1 ]; then
    echo "ERROR: --open only views an existing checkpoint (no --batch, --clean)" >&2
    exit 2
  fi
fi
if ! command -v innovus >/dev/null 2>&1; then
  echo "ERROR: 'innovus' not in PATH (Cadence environment loaded?)" >&2
  exit 2
fi
if [ -z "$OPEN_STAGE" ] && { [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; }; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi
if [ "$MODE" = "gui" ] && [ -z "${DISPLAY:-}" ]; then
  echo "ERROR: no X display for the GUI (ssh -X?) -- or use --batch" >&2
  exit 2
fi

# ------------------------------------------------------------------------
# --open: view a checkpoint, nothing else
# ------------------------------------------------------------------------
if [ -n "$OPEN_STAGE" ]; then
  DB="$BUILD_ROOT/$(checkpoint "$OPEN_STAGE")"
  if [ ! -e "$DB" ]; then
    echo "ERROR: $DB not found -- run the flow up to '$OPEN_STAGE' first" >&2
    exit 2
  fi
  cd "$BUILD_ROOT" || exit 2
  printf 'read_db %s\n' "$(basename "$DB")" > open.tcl
  echo "=== [innovus] open checkpoint $DB (close with 'exit' in the console)"
  innovus -files open.tcl -log open -overwrite
  exit 0
fi

# ------------------------------------------------------------------------
# 1. Genus hand-off
# ------------------------------------------------------------------------
if [ ! -e "$GENUS_ROOT/innovus/${DESIGN_TOP}.db" ]; then
  echo "ERROR: $GENUS_ROOT/innovus/${DESIGN_TOP}.db not found" >&2
  echo "       run ./scripts/genus/genus_syn.sh -b first" >&2
  exit 2
fi

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT" || exit 2
# 02_rv64_floorplan_pnr.tcl reads innovus/cc_chip_top.db from the run directory
ln -sfn "$GENUS_ROOT/innovus" innovus

# Checkpoints and reports of this stage and all later ones are stale now
# (write_db writes a directory per checkpoint)
rm -rf "${DESIGN_TOP}"_{fp,placed,cts,routed}.db "${DESIGN_TOP}"_*.rpt \
       "${DESIGN_TOP}"_routed.{v,def} "${DESIGN_TOP}"_lvs.v "${DESIGN_TOP}".gds

# ------------------------------------------------------------------------
# 2./3. Generated run script: flow up to STAGE, checks after routing
# ------------------------------------------------------------------------
{
  echo "set STOP_AFTER $STAGE"
  echo "source $TCL_DIR/02_rv64_floorplan_pnr.tcl"
  if [ "$STAGE" = "route" ] || [ "$STAGE" = "gds" ]; then
    cat <<EOF
# Physical checks after routing. catch: a missing check must not hide the
# result of the flow itself.
catch { verify_drc -limit 100000 -report ${DESIGN_TOP}_drc.rpt }
catch { verifyProcessAntenna -report ${DESIGN_TOP}_antenna.rpt }
EOF
  fi
  [ "$MODE" = "batch" ] && echo "exit"
} > run.tcl

echo "=== [innovus] 1/3 run 02_rv64_floorplan_pnr.tcl up to '$STAGE' ($MODE) in $BUILD_ROOT"
if [ "$MODE" = "gui" ]; then
  echo "    the Innovus window stays open after the flow; close with 'exit' in the console"
  innovus -files run.tcl -log run -overwrite
  echo "=== [innovus] GUI closed, log: $BUILD_ROOT/run.log"
  exit 0
fi

# Innovus keeps reading stdin after -files; /dev/null makes it exit even if
# the script stopped with an error before its "exit".
innovus -batch -files run.tcl -log run -overwrite < /dev/null > /dev/null 2>&1

# ------------------------------------------------------------------------
# 4. Evaluate (batch)
# ------------------------------------------------------------------------
echo "=== [innovus] 2/3 checkpoints"
RC=0
for s in fp place cts route; do
  db="$(checkpoint "$s")"
  if [ -e "$db" ]; then
    echo "  $s: $db"
  else
    echo "  $s: missing"
    RC=1
  fi
  [ "$s" = "$STAGE" ] && break
done

echo "=== [innovus] 3/3 result"
# Innovus messages: "**ERROR: (IMPxxx-nnn) ..."
if grep -q '^\*\*ERROR' run.log 2>/dev/null; then
  grep '^\*\*ERROR' run.log | head -10
  RC=1
fi

case "$STAGE" in
  cts)   TIMING="${DESIGN_TOP}_cts_timing.rpt" ;;
  route|gds) TIMING="${DESIGN_TOP}_final_timing.rpt" ;;
  *)     TIMING="" ;;
esac
if [ -n "$TIMING" ]; then
  slack="$(grep -iE 'slack' "$TIMING" 2>/dev/null | head -1 | sed 's/^ *//')"
  echo "  worst setup slack: ${slack:-no slack line found in $TIMING}"
fi
if [ "$STAGE" = "route" ] || [ "$STAGE" = "gds" ]; then
  for f in "${DESIGN_TOP}_routed.v" "${DESIGN_TOP}_routed.def" "${DESIGN_TOP}_lvs.v"; do
    if [ -s "$f" ]; then echo "  hand-off:     $f"; else echo "  hand-off:     $f missing"; RC=1; fi
  done
  for r in drc antenna connectivity pg_connectivity; do
    line="$(grep -iE 'total|violation' "${DESIGN_TOP}_$r.rpt" 2>/dev/null | tail -1 | sed 's/^ *//')"
    printf '  %-17s %s\n' "$r:" "${line:-see ${DESIGN_TOP}_$r.rpt}"
  done
fi
if [ "$STAGE" = "gds" ]; then
  if [ -s "${DESIGN_TOP}.gds" ]; then
    echo "  GDS:              ${DESIGN_TOP}.gds ($(du -h "${DESIGN_TOP}.gds" | cut -f1))"
    echo "  GDS merge:        $(tail -1 "${DESIGN_TOP}_gds.rpt" 2>/dev/null)"
    grep -q '^missing' "${DESIGN_TOP}_gds.rpt" 2>/dev/null && RC=1
  else
    echo "  GDS:              ${DESIGN_TOP}.gds missing"
    RC=1
  fi
fi
echo "--- reports: $BUILD_ROOT/${DESIGN_TOP}_*.rpt, log: $BUILD_ROOT/run.log"
echo "--- view a stage: ./scripts/innovus/innovus_pnr.sh --open $STAGE"

if [ $RC -eq 0 ]; then
  echo "PASS  place & route of $DESIGN_TOP up to '$STAGE'"
else
  echo "FAIL  place & route of $DESIGN_TOP (see $BUILD_ROOT/run.log)"
fi
exit $RC
