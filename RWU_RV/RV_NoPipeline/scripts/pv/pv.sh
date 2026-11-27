#!/bin/bash
#===============================================================================
# pv.sh -- physical verification of RV_NoPipeline (cc_chip_top, X-FAB
#          XH018): DRC, LVS and ERC with Pegasus or Calibre
#
# Usage:
#   ./scripts/pv/pv.sh [options]
#
# Options:
#   -m, --mode M    drc | lvs | all (default: all)
#   -t, --tool T    pegasus | calibre (default: PV_TOOL from $XFAB_PATHS,
#                   else pegasus) -- the tool the PDK has rule decks for
#   -j, --cpus N    CPUs per run (default 4)
#   -c, --clean     delete build_pv/ before starting
#   -h, --help      show this help
#
# Steps:
#   1. inputs from Innovus (./scripts/innovus/innovus_pnr.sh -b, stage gds):
#      build_innovus/cc_chip_top.gds, cc_chip_top_lvs.v
#   2. Calibre LVS only: v2lvs converts the Verilog netlist to SPICE
#      (cc_chip_top_lvs.sp, includes the cell CDL)
#   3. ../05_rv64_pv.tcl writes the control files (drc_<n>.ctl, lvs.ctl)
#   4. DRC: one run per deck in DRC_RULES; LVS with ERC: one run
#   5. evaluate: DRC result count per deck, LVS CORRECT/INCORRECT, ERC
#
# Results in build_pv/ (never in git: X-FAB rule names, paths, cells).
#
# Before running:
#   XFAB_PATHS = local X-FAB path file (NDA): DRC_RULES, LVS_RULES,
#                PV_SWITCHES, CDL_FILES, PV_TOOL
#
# Exit code: 0 = DRC clean and LVS correct, 1 = violations / mismatch /
#            tool error, 2 = usage / environment error
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_pv}"
INNOVUS_ROOT="${INNOVUS_ROOT:-$PROJECT_ROOT/build_innovus}"
DESIGN_TOP=cc_chip_top

PV_MODE="all"
TOOL=""
CPUS=4
CLEAN=0

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)  shift; PV_MODE="${1:?--mode needs drc, lvs or all}" ;;
    -t|--tool)  shift; TOOL="${1:?--tool needs pegasus or calibre}" ;;
    -j|--cpus)  shift; CPUS="${1:?--cpus needs a number}" ;;
    -c|--clean) CLEAN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$PV_MODE" in drc|lvs|all) ;; *)
  echo "ERROR: unknown mode '$PV_MODE' (drc | lvs | all)" >&2; exit 2 ;;
esac
if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
  echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
  echo "       (template: $TCL_DIR/xh018_paths_template.tcl)" >&2
  exit 2
fi
if ! command -v tclsh >/dev/null 2>&1; then
  echo "ERROR: tclsh not found" >&2; exit 2
fi
xfab_var() {
  printf 'source {%s}\nif {[info exists %s]} {puts [join $%s "\\n"]}\n' \
    "$XFAB_PATHS" "$1" "$1" | tclsh
}
[ -z "$TOOL" ] && TOOL="$(xfab_var PV_TOOL)"
[ -z "$TOOL" ] && TOOL="pegasus"
case "$TOOL" in pegasus|calibre) ;; *)
  echo "ERROR: unknown tool '$TOOL' (pegasus | calibre)" >&2; exit 2 ;;
esac
NEED="$TOOL"
[ "$TOOL" = "calibre" ] && [ "$PV_MODE" != "drc" ] && NEED="calibre v2lvs"
for t in $NEED; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "ERROR: '$t' not in PATH (environment of the PV tool loaded?)" >&2
    exit 2
  fi
done

GDS="$INNOVUS_ROOT/${DESIGN_TOP}.gds"
LVS_V="$INNOVUS_ROOT/${DESIGN_TOP}_lvs.v"
for f in "$GDS" "$LVS_V"; do
  if [ ! -s "$f" ]; then
    echo "ERROR: $f not found -- run ./scripts/innovus/innovus_pnr.sh -b (stage gds)" >&2
    exit 2
  fi
done

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT" || exit 2
rm -f ./*.ctl ./*.results ./*.summary ./*.report ./*.log

# ------------------------------------------------------------------------
# 1. LVS source netlist
# ------------------------------------------------------------------------
SRC="$LVS_V"
if [ "$TOOL" = "calibre" ] && [ "$PV_MODE" != "drc" ]; then
  echo "=== [pv] v2lvs: Verilog -> SPICE"
  SRC="$BUILD_ROOT/${DESIGN_TOP}_lvs.sp"
  V2LVS_ARGS=(-v "$LVS_V" -o "$SRC" -s0 GND -s1 VDD)
  while read -r c; do [ -n "$c" ] && V2LVS_ARGS+=(-s "$c"); done < <(xfab_var CDL_FILES)
  if ! v2lvs "${V2LVS_ARGS[@]}" > v2lvs.log 2>&1 || [ ! -s "$SRC" ]; then
    echo "ERROR: v2lvs failed, see $BUILD_ROOT/v2lvs.log" >&2; exit 1
  fi
fi

# ------------------------------------------------------------------------
# 2. Control files
# ------------------------------------------------------------------------
tclsh "$TCL_DIR/05_rv64_pv.tcl" "$TOOL" "$GDS" "$SRC" || exit 2

run_pv() {   # <drc|lvs> <control file> <log>
  if [ "$TOOL" = "calibre" ]; then
    calibre -"$1" -hier -turbo "$CPUS" "$2" < /dev/null > "$3" 2>&1
  else
    pegasus -"$1" -dp "$CPUS" "$2" < /dev/null > "$3" 2>&1
  fi
}

RC=0
# ------------------------------------------------------------------------
# 3. DRC
# ------------------------------------------------------------------------
if [ "$PV_MODE" != "lvs" ]; then
  for ctl in drc_*.ctl; do
    n="${ctl%.ctl}"
    echo "=== [pv] DRC $n ($TOOL)"
    run_pv drc "$ctl" "$n.log"
    # VERIFY-LAB: summary line of Pegasus; Calibre writes
    # "TOTAL DRC Results Generated: <n> (<n>)"
    cnt="$(grep -iE 'TOTAL DRC Results Generated|Total.*DRC.*Result' "$n.summary" 2>/dev/null \
           | tail -1 | grep -oE '[0-9]+' | head -1)"
    deck="$(grep -iE '^ *(INCLUDE|include)' "$ctl" | tail -1 | sed 's/.*\///; s/[";]//g')"
    if [ -z "$cnt" ]; then
      echo "    $deck: no result count found, see $BUILD_ROOT/$n.summary, $n.log"
      RC=1
    else
      echo "    $deck: $cnt DRC result(s)"
      [ "$cnt" != "0" ] && RC=1
    fi
  done
fi

# ------------------------------------------------------------------------
# 4. LVS + ERC
# ------------------------------------------------------------------------
if [ "$PV_MODE" != "drc" ]; then
  echo "=== [pv] LVS + ERC ($TOOL)"
  run_pv lvs lvs.ctl lvs.log
  # VERIFY-LAB: Pegasus report wording; Calibre: "CORRECT" / "INCORRECT"
  if grep -qiE 'INCORRECT|MISMATCH|NOT MATCH' lvs.report 2>/dev/null; then
    echo "    LVS: INCORRECT (see $BUILD_ROOT/lvs.report)"
    RC=1
  elif grep -qE 'CORRECT|MATCH' lvs.report 2>/dev/null; then
    echo "    LVS: CORRECT"
  else
    echo "    LVS: no result found (see $BUILD_ROOT/lvs.report, lvs.log)"
    RC=1
  fi
  erc="$(grep -iE 'TOTAL ERC Results Generated|Total.*ERC.*Result' erc.summary 2>/dev/null \
         | tail -1 | grep -oE '[0-9]+' | head -1)"
  echo "    ERC: ${erc:-?} result(s) (erc.summary)"
  [ -n "$erc" ] && [ "$erc" != "0" ] && RC=1
fi

echo "--- results: $BUILD_ROOT (*.summary, lvs.report, *.results)"
if [ $RC -eq 0 ]; then
  echo "PASS  physical verification of $DESIGN_TOP ($PV_MODE, $TOOL)"
else
  echo "FAIL  physical verification of $DESIGN_TOP ($PV_MODE, $TOOL)"
fi
exit $RC
