#!/bin/bash
#===============================================================================
# xrun_regression.sh -- run the RV64I regression with Cadence Xcelium (batch)
#
# Usage:
#   ./scripts/xcelium/xrun_regression.sh [options] [test ...]
#
#   without test names: all tests from ASM_TESTS in CMakeLists.txt
#   with test names:    only these, e.g.  instr30beq instr31bne
#
# Options:
#   -t, --timeout S abort a single test after S seconds (default 300)
#   -c, --clean     delete build_xcelium/ before starting
#   -h, --help      show this help
#
# Tests run one after another on purpose: the RWU license server has only
# 2 Xcelium simulation licenses for all users (one regression takes ~1-2 min).
#
# Every test is run by xrun_single.sh --batch in its own directory
# build_xcelium/<test>/. The summary is written to
#   build_xcelium/regression.txt
# (the xsim/CMake flow writes ./regression.txt -- both can coexist).
#
# Exit code: number of failed tests (0 = regression passed)
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_xcelium}"
SINGLE="$SCRIPT_DIR/xrun_single.sh"

TIMEOUT=300
CLEAN=0
TESTS=()

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--timeout) shift; TIMEOUT="${1:?--timeout needs a value}" ;;
    -c|--clean)   CLEAN=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "ERROR: unknown option $1" >&2; usage >&2; exit 255 ;;
    *)            TESTS+=("$1") ;;
  esac
  shift
done

if [ ${#TESTS[@]} -eq 0 ]; then
  mapfile -t TESTS < <("$SINGLE" --list)
fi

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

REPORT="$BUILD_ROOT/regression.txt"
START=$(date +%s)

echo "=== Xcelium regression: ${#TESTS[@]} tests, timeout ${TIMEOUT}s"

run_one() {
  local t="$1" t0 rc
  t0=$(date +%s)
  mkdir -p "$BUILD_ROOT/$t"
  "$SINGLE" --batch --timeout "$TIMEOUT" "$t" > "$BUILD_ROOT/$t/run.log" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    printf 'PASS  %-20s %4ss\n' "$t" "$(( $(date +%s) - t0 ))" | tee -a "$REPORT"
  else
    printf 'FAIL  %-20s %4ss  -> %s\n' "$t" "$(( $(date +%s) - t0 ))" \
      "build_xcelium/$t/run.log" | tee -a "$REPORT"
  fi
}

echo "=== RV64I XCELIUM REGRESSION REPORT  $(date '+%Y-%m-%d %H:%M') ===" > "$REPORT"
echo >> "$REPORT"
for t in "${TESTS[@]}"; do
  run_one "$t"
done

NPASS=$(grep -c '^PASS' "$REPORT")
NFAIL=$(grep -c '^FAIL' "$REPORT")
{
  echo
  echo "Passed: $NPASS / ${#TESTS[@]}   Failed: $NFAIL   Time: $(( $(date +%s) - START ))s"
  if [ "$NFAIL" -eq 0 ]; then echo "Regression PASSED"; else echo "Regression FAILED"; fi
} | tee -a "$REPORT"

echo "Report: $REPORT"
exit "$NFAIL"
