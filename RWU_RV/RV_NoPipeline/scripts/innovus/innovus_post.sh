#!/bin/bash
#===============================================================================
# innovus_post.sh -- post-route optimization and finishing of RV_NoPipeline
#                    (cc_chip_top, X-FAB XH018) with Cadence Innovus
#
# Usage:
#   ./scripts/innovus/innovus_post.sh [options]
#
# Options:
#   -b, --batch       no GUI: run, check, print a summary, exit (default:
#                     GUI, the window stays open)
#   -s, --stop STAGE  stop after STAGE: opt | finish | gds (default)
#                       opt     setup/hold/DRV optimization after routing
#                       finish  core fillers, metal fill, hand-off netlists
#                               and DEF
#                       gds     merged GDS with pad labels
#   -x, --extract E   extraction effort for the optimization: medium
#                     (default, built-in) | high | signoff (Quantus engine,
#                     needs a Quantus licence)
#   -o, --open STAGE  do not run anything: open the checkpoint of STAGE
#                     (opt: cc_chip_top_postopt.db, finish/gds: _final.db)
#   -h, --help        show this help
#
# Steps:
#   1. input: build_innovus/cc_chip_top_routed.db (innovus_pnr.sh)
#   2. run ../02d_rv64_postroute.tcl up to STAGE (batch or GUI)
#   3. on the final layout: DRC and antenna check
#   4. batch: worst setup/hold slack before and after, DRC, antenna,
#      density, connectivity, hand-off files, GDS
#
# Results in build_innovus/ (with the P&R results; never in git).
# Next: ./scripts/quantus/quantus_rcx.sh, ./scripts/sta/sta.sh -b (06),
# ./scripts/lec/lec.sh (07), ./scripts/pv/pv.sh (08)
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA): CORE_FILLERS, FILL_LAYERS,
#                STREAM_MAP, GDS_FILES, GDS_UNIT, LABEL_LAYER, pad cells
#
# Exit code: 0 = ran through, no setup/hold violation, GDS complete;
#            1 = Innovus error / violation / missing output;
#            2 = usage / environment error
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_innovus}"
DESIGN_TOP=cc_chip_top

MODE="gui"
STAGE="gds"
EXTRACT="medium"
OPEN_STAGE=""

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

checkpoint() {
  case "$1" in
    opt)        echo "${DESIGN_TOP}_postopt.db" ;;
    finish|gds) echo "${DESIGN_TOP}_final.db" ;;
    *)          return 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--batch)   MODE="batch" ;;
    -s|--stop)    shift; STAGE="${1:?--stop needs a stage}" ;;
    -x|--extract) shift; EXTRACT="${1:?--extract needs medium, high or signoff}" ;;
    -o|--open)    shift; OPEN_STAGE="${1:?--open needs a stage}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! checkpoint "$STAGE" >/dev/null; then
  echo "ERROR: unknown stage '$STAGE' (opt | finish | gds)" >&2; exit 2
fi
case "$EXTRACT" in medium|high|signoff) ;; *)
  echo "ERROR: unknown extraction effort '$EXTRACT' (medium | high | signoff)" >&2; exit 2 ;;
esac
if ! command -v innovus >/dev/null 2>&1; then
  echo "ERROR: 'innovus' not in PATH (Cadence environment loaded?)" >&2
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
  if ! checkpoint "$OPEN_STAGE" >/dev/null; then
    echo "ERROR: unknown stage '$OPEN_STAGE' (opt | finish | gds)" >&2; exit 2
  fi
  DB="$BUILD_ROOT/$(checkpoint "$OPEN_STAGE")"
  if [ ! -e "$DB" ]; then
    echo "ERROR: $DB not found -- run up to '$OPEN_STAGE' first" >&2; exit 2
  fi
  cd "$BUILD_ROOT" || exit 2
  printf 'read_db %s\n' "$(basename "$DB")" > open_post.tcl
  echo "=== [innovus-post] open checkpoint $DB (close with 'exit' in the console)"
  innovus -files open_post.tcl -log open_post -overwrite
  exit 0
fi

if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi

# ------------------------------------------------------------------------
# 1. Input: routed checkpoint
# ------------------------------------------------------------------------
if [ ! -e "$BUILD_ROOT/${DESIGN_TOP}_routed.db" ]; then
  echo "ERROR: $BUILD_ROOT/${DESIGN_TOP}_routed.db not found" >&2
  echo "       run ./scripts/innovus/innovus_pnr.sh -b first" >&2
  exit 2
fi
cd "$BUILD_ROOT" || exit 2

# Results of this step are stale now; the P&R checkpoints stay
rm -rf "${DESIGN_TOP}"_{postopt,final}.db timing_pre timing_post \
       "${DESIGN_TOP}"_post_*_pre.rpt "${DESIGN_TOP}"_final_*.rpt \
       "${DESIGN_TOP}"_{density,connectivity,drc,antenna,gds}.rpt \
       "${DESIGN_TOP}"_routed.{v,def} "${DESIGN_TOP}"_lvs.v \
       "${DESIGN_TOP}".gds "${DESIGN_TOP}"_labels.txt

# ------------------------------------------------------------------------
# 2./3. Generated run script
# ------------------------------------------------------------------------
{
  echo "set STOP_AFTER     $STAGE"
  echo "set EXTRACT_EFFORT $EXTRACT"
  echo "source $TCL_DIR/02d_rv64_postroute.tcl"
  if [ "$STAGE" != "opt" ]; then
    echo "# Physical checks on the final layout. catch: a missing check must not"
    echo "# hide the result of the flow itself."
    echo "catch { verify_drc -limit 100000 -report ${DESIGN_TOP}_drc.rpt }"
    echo "catch { verifyProcessAntenna -report ${DESIGN_TOP}_antenna.rpt }"
  fi
  [ "$MODE" = "batch" ] && echo "exit"
} > run_post.tcl

echo "=== [innovus-post] 1/3 run 02d_rv64_postroute.tcl up to '$STAGE' ($MODE, extraction $EXTRACT)"
if [ "$MODE" = "gui" ]; then
  echo "    the Innovus window stays open after the flow; close with 'exit' in the console"
  innovus -files run_post.tcl -log run_post -overwrite
  echo "=== [innovus-post] GUI closed, log: $BUILD_ROOT/run_post.log"
  exit 0
fi
innovus -batch -files run_post.tcl -log run_post -overwrite < /dev/null > /dev/null 2>&1

# ------------------------------------------------------------------------
# 4. Evaluate (batch)
# ------------------------------------------------------------------------
echo "=== [innovus-post] 2/3 checkpoints"
RC=0
for s in opt finish; do
  db="$(checkpoint "$s")"
  if [ -e "$db" ]; then echo "  $s: $db"; else echo "  $s: missing"; RC=1; fi
  [ "$s" = "$STAGE" ] && break
done

echo "=== [innovus-post] 3/3 result"
if grep -q '^\*\*ERROR' run_post.log 2>/dev/null; then
  grep '^\*\*ERROR' run_post.log | head -10
  RC=1
fi

# Worst slack = number on the first slack line of a report
slack_of() { grep -iE 'slack' "$1" 2>/dev/null | head -1 | grep -oE -- '-?[0-9]+\.[0-9]+' | tail -1; }
for kind in setup hold; do
  if [ "$kind" = "setup" ]; then pre="${DESIGN_TOP}_post_setup_pre.rpt"; post="${DESIGN_TOP}_final_timing.rpt"
  else                           pre="${DESIGN_TOP}_post_hold_pre.rpt";  post="${DESIGN_TOP}_final_hold.rpt"; fi
  b="$(slack_of "$pre")"; a="$(slack_of "$post")"
  flag=""
  case "$a" in -*) flag="  VIOLATED"; RC=1 ;; "") flag="  (see $post)" ;; esac
  printf '  worst %-5s slack: before %s, after %s%s\n' "$kind" "${b:-?}" "${a:-?}" "$flag"
done

if [ "$STAGE" != "opt" ]; then
  for r in drc antenna density connectivity; do
    line="$(grep -iE 'total|violation' "${DESIGN_TOP}_$r.rpt" 2>/dev/null | tail -1 | sed 's/^ *//')"
    printf '  %-17s %s\n' "$r:" "${line:-see ${DESIGN_TOP}_$r.rpt}"
  done
  for f in "${DESIGN_TOP}_routed.v" "${DESIGN_TOP}_routed.def" "${DESIGN_TOP}_lvs.v"; do
    if [ -s "$f" ]; then echo "  hand-off:         $f"; else echo "  hand-off:         $f missing"; RC=1; fi
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
echo "--- reports: $BUILD_ROOT/${DESIGN_TOP}_*.rpt, timing_pre/, timing_post/, log: run_post.log"

if [ $RC -eq 0 ]; then
  echo "PASS  post-route step of $DESIGN_TOP up to '$STAGE'"
else
  echo "FAIL  post-route step of $DESIGN_TOP (see $BUILD_ROOT/run_post.log)"
fi
exit $RC
