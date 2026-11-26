#!/bin/bash
#===============================================================================
# xrun_single.sh -- run ONE RV64I test case with Cadence Xcelium (xrun)
#
# Usage:
#   ./scripts/xcelium/xrun_single.sh [options] <test>
#
#   <test>          name of an assembler test in rv64Sim/ without .asm,
#                   e.g. instr06addi, instr30beq, readgpioid
#
# Options:
#   -b, --batch     no GUI (default: SimVision GUI)
#   -w, --waves     batch only: record all signals into waves.shm
#                   (view later with: simvision build_xcelium/<test>/waves.shm)
#   -t, --timeout S batch only: abort after S seconds (default 300), including
#                   the time spent waiting for a free license
#   -l, --list      list all available tests and exit
#   -h, --help      show this help
#
# Steps:
#   1. assemble  rv64Sim/<test>.asm -> riscvtest.mem   (RISC-V binutils)
#   2. compile + elaborate + simulate in one xrun call
#   3. evaluate  error.txt written by the testbench ("Test ok" / "Test fail")
#
# All results go to build_xcelium/<test>/ (xrun.log, error.txt, waves.shm).
#
# Licenses: the RWU license server has only 2 Xcelium simulation licenses
# for ALL users. -licqueue makes xrun wait for a free one instead of failing.
# An open SimVision GUI keeps its license until you close it.
#
# Exit code: 0 = test ok, 1 = test failed/no result, 2 = usage/tool error
#
# Single source of truth: the RTL file list is read from sim/CMakeLists.txt
# (SOURCES_SV) and the test table (name, expected GPIO value) from
# CMakeLists.txt (INSTR_TB_CONFIG), so this script never has to be edited
# when a file or a test is added to the CMake flow.
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IP_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_xcelium}"
echo "Script-Dir: $SCRIPT_DIR"
echo "Project-Root: $PROJECT_ROOT"
echo "IP-Root: $IP_ROOT"
echo "Build-Root: $BUILD_ROOT"

MODE="gui"
WAVES=0
TIMEOUT=300
TEST=""

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

# All tests from ASM_TESTS in CMakeLists.txt (one name per line)
list_tests() {
  sed -n '/^set(ASM_TESTS/,/^)/p' "$PROJECT_ROOT/CMakeLists.txt" \
    | grep -v '^set(\|^)' | sed 's/#.*//' | awk 'NF {print $1}'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--batch)   MODE="batch" ;;
    -w|--waves)   WAVES=1 ;;
    -t|--timeout) shift; TIMEOUT="${1:?--timeout needs a value}" ;;
    -l|--list)    list_tests; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)            TEST="$1" ;;
  esac
  shift
done

if [ -z "$TEST" ]; then
  echo "ERROR: no test given. Available tests: ./scripts/xcelium/xrun_single.sh --list" >&2
  exit 2
fi

ASM_FILE="$PROJECT_ROOT/rv64Sim/$TEST.asm"
if [ ! -f "$ASM_FILE" ]; then
  echo "ERROR: $ASM_FILE not found" >&2
  exit 2
fi

for tool in xrun cmake; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not in PATH (Cadence environment loaded?)" >&2
    exit 2
  fi
done

# ------------------------------------------------------------------------
# Testbench selection -- same rule as CMakeLists.txt:
# tests listed in INSTR_TB_CONFIG share tb_rv64i_instr.sv and get their
# name/expected GPIO value as plusargs; all others have their own testbench.
# ------------------------------------------------------------------------
CFG_LINE="$(sed -n '/^set(INSTR_TB_CONFIG/,/^)/p' "$PROJECT_ROOT/CMakeLists.txt" \
            | sed 's/#.*//' | tr -d '"' | awk -v t="$TEST" '$1 == t {print $2, $3}')"
echo "Tests-CFG-Line: $CFG_LINE"

if [ -n "$CFG_LINE" ]; then
  TB_FILE="$PROJECT_ROOT/tb/tb_rv64i_instr.sv"
  read -r TB_NAME TB_EXPECTED <<< "$CFG_LINE"
  PLUSARGS=("+TEST_NAME=$TB_NAME" "+EXPECTED=$TB_EXPECTED")
else
  TB_FILE="$PROJECT_ROOT/tb/tb_rv64i_$TEST.sv"
  PLUSARGS=()
fi

if [ ! -f "$TB_FILE" ]; then
  echo "ERROR: testbench $TB_FILE not found" >&2
  exit 2
fi

WORK="$BUILD_ROOT/$TEST"
mkdir -p "$WORK"
cd "$WORK" || exit 2

# ------------------------------------------------------------------------
# 1. Assemble (reuses rv64Sim/CMakeLists.txt: as -> ld -> objcopy)
# ------------------------------------------------------------------------
echo "=== [$TEST] 1/3 assemble $ASM_FILE"
if ! { cmake -DASM_FILE="$ASM_FILE" -S "$PROJECT_ROOT/rv64Sim" -B asm \
       && cmake --build asm --target mem; } > asm.log 2>&1; then
  echo "ERROR: assembling failed, see $WORK/asm.log" >&2
  exit 2
fi
# $readmemh in the testbench and in asIMem.sv opens riscvtest.mem in the cwd
cp asm/rv64i.mem riscvtest.mem

# ------------------------------------------------------------------------
# 2. File list (generated from sim/CMakeLists.txt) + run scripts
# ------------------------------------------------------------------------
sed -n '/^set(SOURCES_SV/,/^)/p' "$PROJECT_ROOT/sim/CMakeLists.txt" \
  | sed 's/#.*//' \
  | grep -o '\${[A-Z_]*}/[^ ]*\.sv' \
  | grep -v 'TB_FILE' \
  | sed "s#\${PROJECT_ROOT}#$PROJECT_ROOT#; s#\${IP_ROOT}#$IP_ROOT#" > rtl_files.f
echo "$TB_FILE" >> rtl_files.f

# A local, empty cds.lib keeps a user's ~/cds.lib (Virtuoso libraries etc.)
# out of the simulation -- otherwise every tool prints DLCPTH warnings for
# libraries that have nothing to do with this design.
: > cds.lib

# The testbench appends to error.txt -- start from a clean file so the
# result below belongs to this run only.
rm -f error.txt

if [ "$MODE" = "gui" ]; then
  cat > run.tcl <<'EOF'
database -open waves -shm -default
probe -create tb_rv64i -all -depth all -memories
run
EOF
  GUI_ARGS=(-gui -simvisargs "-input $SCRIPT_DIR/waves.svcf")
else
  if [ "$WAVES" -eq 1 ]; then
    cat > run.tcl <<'EOF'
database -open waves -shm -default
probe -create tb_rv64i -all -depth all -memories
run
exit
EOF
  else
    printf 'run\nexit\n' > run.tcl
  fi
  GUI_ARGS=()
fi

XRUN_ARGS=(
  -sv
  -define LOGIC_SV
  -timescale 1ns/1ps
  -cdslib ./cds.lib
  -f rtl_files.f
  -top tb_rv64i
  -access +rwc
  -licqueue
  -nowarn MEMODR
  -nowarn CUVWSP
  -input run.tcl
  -l xrun.log
  "${PLUSARGS[@]}"
  "${GUI_ARGS[@]}"
)

# ------------------------------------------------------------------------
# 3. Simulate
# ------------------------------------------------------------------------
echo "=== [$TEST] 2/3 xrun ($MODE) in $WORK"
echo "    xrun ${XRUN_ARGS[*]}"
echo "    xrun ${XRUN_ARGS[*]}" > xrun.cmd

if [ "$MODE" = "gui" ]; then
  xrun "${XRUN_ARGS[@]}"
  RC=$?
else
  # The testbenches end with $stop when the test is decided. A program that
  # never reaches its check would run forever -- the timeout catches that.
  timeout "$TIMEOUT" xrun "${XRUN_ARGS[@]}" > /dev/null 2>&1
  RC=$?
  if [ $RC -eq 124 ]; then
    echo "$TEST: Test fail (timeout after ${TIMEOUT}s)" >> error.txt
  fi
fi

# ------------------------------------------------------------------------
# 4. Evaluate
# ------------------------------------------------------------------------
echo "=== [$TEST] 3/3 result"
if grep -q '\*[EF],' xrun.log 2>/dev/null; then
  grep '\*[EF],' xrun.log | head -10
  echo "FAIL  $TEST  (xrun errors, see $WORK/xrun.log)"
  exit 1
fi

if [ -f error.txt ] && grep -q 'Test ok' error.txt && ! grep -q 'Test fail' error.txt; then
  echo "PASS  $TEST"
  exit 0
fi

[ -f error.txt ] && cat error.txt
echo "FAIL  $TEST  (see $WORK/xrun.log, rc=$RC)"
exit 1
