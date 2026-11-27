#!/bin/bash
#===============================================================================
# gatesim.sh -- gate-level simulation of RV_NoPipeline (cc_chip_top, X-FAB
#               XH018) with Cadence Xcelium (xrun)
#
# Usage:
#   ./scripts/gatesim/gatesim.sh [options] <test>
#   ./scripts/gatesim/gatesim.sh -r [options]
#
#   <test>          instr06addi ... instr60ebreak   instruction test
#                   instr99bscan                    boundary scan
#                   scan                            internal scan chain
#                   (list: --list)
#
# Options:
#   -b, --batch     no GUI (default: SimVision GUI)
#   -r, --regress   all tests one after another, batch; summary in
#                   build_gatesim/regression.txt
#   -s, --sdf       annotate the SDF and run the timing checks; default:
#                   functional, no specify blocks (-nospecify).
#                   Synthesis netlist: Genus SDF (cc_chip_top_syn.sdf, slow
#                   corner). With -p: Tempus SDF with the Quantus
#                   parasitics (build_sta/cc_chip_top_sta_func.sdf, for the
#                   test 'scan' _sta_scan.sdf), max delays = slow corner
#   -p, --postroute post-route netlist from Innovus (innovus_post.sh,
#                   build_innovus/cc_chip_top_routed.v, with the clock
#                   tree) instead of the Genus netlist; results in
#                   build_gatesim/postroute/
#   -m, --min       with -p -s: min delays of the SDF (fast corner, hold
#                   check) instead of the max delays (slow corner, setup)
#   -u, --unit      unit delay instead of zero delay (-delay_mode unit), for
#                   races in the clock mux/clock gate cells without SDF
#   --rtl           reference run: the same testbench on the RTL of
#                   cc_chip_top (behavioural pads), no X-FAB file needed
#   -L, --scanlen N scan chain length for 'scan' (default: from
#                   build_genus/cc_chip_top_scan_chains.rpt; --rtl: 0)
#   -n, --netdir D  Genus result directory (default: build_genus)
#   -w, --waves     batch only: record all signals into waves.shm
#   -t, --timeout S abort one test after S seconds (default 1800)
#   -c, --clean     delete build_gatesim/ before starting
#   -l, --list      list the tests and exit
#   -h, --help      show this help
#
# Testbench: tb/gls/tb_gls_chip.sv. It only uses the bond pads and loads the
# program through JTAG (the SPRAM model has no start-up content), so it runs
# unchanged on the netlist and on the RTL.
#
# Before running (netlist):
#   build_genus/   from ./scripts/genus/genus_syn.sh -b: cc_chip_top_syn.v,
#                  _syn.sdf, _scan_chains.rpt
#   XFAB_PATHS     local X-FAB path file (NDA) with VLOG_MODELS (Verilog
#                  models of D_CELLS_HD, IO_CELLS_3V, I-Mem/D-Mem macro) and
#                  optionally VLOG_DEFINES (template:
#                  scripts/xh018_paths_template.tcl)
#
#   post-route (-p): build_innovus/cc_chip_top_routed.v, with -s
#                  build_sta/cc_chip_top_sta_{func,scan}.sdf (scripts/sta);
#                  the scan chain length still comes from build_genus/
#
# Results in build_gatesim/<test>/ (xrun.log, error.txt, waves.shm), with -p
# in build_gatesim/postroute/<test>/.
# Licenses: like xrun_single.sh, -licqueue waits for one of the 2 licenses.
#
# Exit code: 0 = test(s) ok, 1 = test failed, 2 = usage/tool error
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IP_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build_gatesim}"
DESIGN_TOP=cc_chip_top
TB_FILE="$PROJECT_ROOT/tb/gls/tb_gls_chip.sv"

MODE="gui"
REGRESS=0
SDF=0
POSTROUTE=0
MTM="MAXIMUM"
UNIT=0
RTL=0
SCANLEN=""
NETDIR="$PROJECT_ROOT/build_genus"
INNOVUS_ROOT="${INNOVUS_ROOT:-$PROJECT_ROOT/build_innovus}"
STA_ROOT="${STA_ROOT:-$PROJECT_ROOT/build_sta}"
WAVES=0
TIMEOUT=1800
CLEAN=0
TEST=""
ARGS_ORIG=("$@")

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//; /^====/d'; }

# Instruction tests (INSTR_TB_CONFIG in CMakeLists.txt: name label expected)
instr_table() {
  sed -n '/^set(INSTR_TB_CONFIG/,/^)/p' "$PROJECT_ROOT/CMakeLists.txt" \
    | sed 's/#.*//' | tr -d '"' | awk 'NF == 3 {print $1, $2, $3}'
}
list_tests() { instr_table | awk '{print $1}'; echo instr99bscan; echo scan; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--batch)   MODE="batch" ;;
    -r|--regress) REGRESS=1; MODE="batch" ;;
    -s|--sdf)     SDF=1 ;;
    -p|--postroute) POSTROUTE=1 ;;
    -m|--min)     MTM="MINIMUM" ;;
    -u|--unit)    UNIT=1 ;;
    --rtl)        RTL=1 ;;
    -L|--scanlen) shift; SCANLEN="${1:?--scanlen needs a value}" ;;
    -n|--netdir)  shift; NETDIR="$(cd "${1:?--netdir needs a value}" && pwd)" || exit 2 ;;
    -w|--waves)   WAVES=1 ;;
    -t|--timeout) shift; TIMEOUT="${1:?--timeout needs a value}" ;;
    -c|--clean)   CLEAN=1 ;;
    -l|--list)    list_tests; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)            TEST="$1" ;;
  esac
  shift
done

if [ "$POSTROUTE" -eq 1 ] && [ "$RTL" -eq 1 ]; then
  echo "ERROR: --postroute and --rtl exclude each other" >&2; exit 2
fi
if [ "$MTM" = "MINIMUM" ] && { [ "$POSTROUTE" -eq 0 ] || [ "$SDF" -eq 0 ]; }; then
  echo "ERROR: --min needs --postroute and --sdf (only the Tempus SDF has min delays)" >&2; exit 2
fi
[ "$POSTROUTE" -eq 1 ] && BUILD_ROOT="$BUILD_ROOT/postroute"

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

# ------------------------------------------------------------------------
# Regression: this script once per test, batch
# ------------------------------------------------------------------------
if [ "$REGRESS" -eq 1 ]; then
  PASS_ARGS=()
  for a in "${ARGS_ORIG[@]}"; do
    case "$a" in -r|--regress|-c|--clean) ;; *) PASS_ARGS+=("$a") ;; esac
  done
  REPORT="$BUILD_ROOT/regression.txt"
  KIND="netlist"; [ "$RTL" -eq 1 ] && KIND="RTL reference"
  [ "$POSTROUTE" -eq 1 ] && KIND="post-route netlist"
  [ "$SDF" -eq 1 ] && KIND="$KIND, SDF"
  [ "$POSTROUTE" -eq 1 ] && [ "$SDF" -eq 1 ] && KIND="$KIND $MTM"
  echo "=== RV64I GATE-LEVEL REGRESSION ($KIND)  $(date '+%Y-%m-%d %H:%M') ===" > "$REPORT"
  NFAIL=0
  for t in $(list_tests); do
    t0=$(date +%s)
    mkdir -p "$BUILD_ROOT/$t"
    "$0" "${PASS_ARGS[@]}" --batch "$t" > "$BUILD_ROOT/$t/run.log" 2>&1
    if [ $? -eq 0 ]; then
      printf 'PASS  %-20s %5ss\n' "$t" "$(( $(date +%s) - t0 ))" | tee -a "$REPORT"
    else
      printf 'FAIL  %-20s %5ss  -> %s\n' "$t" "$(( $(date +%s) - t0 ))" \
        "${BUILD_ROOT#$PROJECT_ROOT/}/$t/run.log" | tee -a "$REPORT"
      NFAIL=$((NFAIL + 1))
    fi
  done
  echo "--- $NFAIL test(s) failed, summary: $REPORT"
  [ "$NFAIL" -eq 0 ] && exit 0 || exit 1
fi

# ------------------------------------------------------------------------
# Single test: checks
# ------------------------------------------------------------------------
if [ -z "$TEST" ]; then
  echo "ERROR: no test given (list: $0 --list)" >&2
  exit 2
fi
for tool in xrun cmake; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not in PATH (Cadence environment loaded?)" >&2
    exit 2
  fi
done
if [ "$MODE" = "gui" ] && [ -z "${DISPLAY:-}" ]; then
  echo "ERROR: no X display for the GUI (ssh -X?) -- or use --batch" >&2
  exit 2
fi

# Reads a list variable from the X-FAB path file. tclsh evaluates the file
# exactly as Genus does; without tclsh a plain "set NAME [list a b]" or
# "set NAME value" line is parsed.
xfab_var() {
  local name="$1"
  if command -v tclsh >/dev/null 2>&1; then
    printf 'source {%s}\nif {[info exists %s]} {puts [join $%s "\\n"]}\n' \
      "$XFAB_PATHS" "$name" "$name" | tclsh
  else
    sed -n "s/^[[:space:]]*set[[:space:]]\+$name[[:space:]]\+//p" "$XFAB_PATHS" \
      | sed 's/;#.*//; s/\[list//; s/\]//' | tr -s ' \t' '\n' | sed '/^$/d'
  fi
}

PLUSARGS=()
PROG=""
case "$TEST" in
  scan)
    PLUSARGS+=("+MODE=scan")
    if [ -z "$SCANLEN" ]; then
      if [ "$RTL" -eq 1 ]; then
        SCANLEN=0
      else
        # VERIFY-LAB: format of report_scan_chains -- the length of sc01 is
        # taken as the last number on the first line that names sc01.
        RPT="$NETDIR/${DESIGN_TOP}_scan_chains.rpt"
        SCANLEN="$(grep -m1 -i 'sc01' "$RPT" 2>/dev/null | sed 's/sc01//I' \
                   | grep -oE '[0-9]+' | tail -1)"
        if [ -z "$SCANLEN" ]; then
          echo "ERROR: no chain length found in $RPT -- give it with -L <n>" >&2
          exit 2
        fi
        echo "    scan chain length $SCANLEN from $RPT (override: -L <n>)"
      fi
    fi
    PLUSARGS+=("+SCAN_LENGTH=$SCANLEN")
    ;;
  instr99bscan)
    PLUSARGS+=("+MODE=bscan")
    PROG="$TEST"
    ;;
  *)
    CFG="$(instr_table | awk -v t="$TEST" '$1 == t {print $2, $3}')"
    if [ -z "$CFG" ]; then
      echo "ERROR: unknown test $TEST (list: $0 --list)" >&2
      exit 2
    fi
    read -r TB_NAME TB_EXPECTED <<< "$CFG"
    PLUSARGS+=("+MODE=instr" "+TEST_NAME=$TB_NAME" "+EXPECTED=$TB_EXPECTED")
    PROG="$TEST"
    ;;
esac

WORK="$BUILD_ROOT/$TEST"
mkdir -p "$WORK"
cd "$WORK" || exit 2

# ------------------------------------------------------------------------
# 1. Program image -> gls_prog.mem (the testbench loads it through JTAG)
# ------------------------------------------------------------------------
rm -f gls_prog.mem riscvtest.mem
if [ -n "$PROG" ]; then
  echo "=== [$TEST] 1/3 assemble rv64Sim/$PROG.asm"
  if ! { cmake -DASM_FILE="$PROJECT_ROOT/rv64Sim/$PROG.asm" -S "$PROJECT_ROOT/rv64Sim" -B asm \
         && cmake --build asm --target mem; } > asm.log 2>&1; then
    echo "ERROR: assembling failed, see $WORK/asm.log" >&2
    exit 2
  fi
  # Not riscvtest.mem: the RTL I-Mem would preload it and hide the JTAG load.
  cp asm/rv64i.mem gls_prog.mem
else
  echo "=== [$TEST] 1/3 no program (scan test)"
fi

# ------------------------------------------------------------------------
# 2. File list
# ------------------------------------------------------------------------
DEFINES=()
SIM_ARGS=()
if [ "$RTL" -eq 1 ]; then
  sed -n '/^set(SOURCES_SV/,/^)/p' "$PROJECT_ROOT/sim/CMakeLists.txt" \
    | sed 's/#.*//' \
    | grep -o '\${[A-Z_]*}/[^ ]*\.sv' \
    | grep -v 'TB_FILE' \
    | sed "s#\${PROJECT_ROOT}#$PROJECT_ROOT#; s#\${IP_ROOT}#$IP_ROOT/#" > files.f
  for f in cc_pad_in cc_pad_out cc_pad_bidir cc_chip_top; do
    echo "$PROJECT_ROOT/src/$f.sv" >> files.f
  done
  DEFINES+=(-define LOGIC_SV)
  KIND="RTL reference"
else
  if [ -z "${XFAB_PATHS:-}" ] || [ ! -r "$XFAB_PATHS" ]; then
    echo "ERROR: XFAB_PATHS must point to the local X-FAB path file" >&2
    exit 2
  fi
  if [ "$POSTROUTE" -eq 1 ]; then
    NETLIST="$INNOVUS_ROOT/${DESIGN_TOP}_routed.v"
    HINT="./scripts/innovus/innovus_post.sh -b or ./scripts/quantus/quantus_rcx.sh"
  else
    NETLIST="$NETDIR/${DESIGN_TOP}_syn.v"
    HINT="./scripts/genus/genus_syn.sh -b"
  fi
  if [ ! -r "$NETLIST" ]; then
    echo "ERROR: netlist $NETLIST not found ($HINT)" >&2
    exit 2
  fi
  mapfile -t MODELS < <(xfab_var VLOG_MODELS)
  if [ ${#MODELS[@]} -eq 0 ]; then
    echo "ERROR: VLOG_MODELS not set in $XFAB_PATHS" >&2
    exit 2
  fi
  # as_pack: only the package (constants for the testbench), no RTL module
  echo "$PROJECT_ROOT/src/as_pack.sv" > files.f
  for m in "${MODELS[@]}"; do
    if [ ! -r "$m" ]; then echo "ERROR: model $m not found" >&2; exit 2; fi
    echo "$m" >> files.f
  done
  echo "$NETLIST" >> files.f
  while read -r d; do
    [ -n "$d" ] && DEFINES+=(-define "$d")
  done < <(xfab_var VLOG_DEFINES)
  KIND="netlist $NETLIST"
  if [ "$SDF" -eq 1 ]; then
    if [ "$POSTROUTE" -eq 0 ]; then
      SDF_FILE="$NETDIR/${DESIGN_TOP}_syn.sdf"
    elif [ "$TEST" = "scan" ]; then
      SDF_FILE="$STA_ROOT/${DESIGN_TOP}_sta_scan.sdf"
    else
      SDF_FILE="$STA_ROOT/${DESIGN_TOP}_sta_func.sdf"
    fi
    if [ ! -r "$SDF_FILE" ]; then echo "ERROR: $SDF_FILE not found" >&2; exit 2; fi
    cat > sdf.cmd <<EOF
SDF_FILE    = "$SDF_FILE",
SCOPE       = tb_gls.DUT,
MTM_CONTROL = "$MTM",
LOG_FILE    = "sdf.log";
EOF
    SIM_ARGS+=(-sdf_cmd_file sdf.cmd)
    KIND="$KIND + SDF ($MTM)"
  else
    # Functional: no specify path delays and no timing checks
    SIM_ARGS+=(-nospecify)
  fi
fi
[ "$UNIT" -eq 1 ] && SIM_ARGS+=(-delay_mode unit)
echo "$TB_FILE" >> files.f

: > cds.lib
rm -f error.txt

if [ "$MODE" = "gui" ] || [ "$WAVES" -eq 1 ]; then
  printf 'database -open waves -shm -default\nprobe -create tb_gls -all -depth all -memories\nrun\n' > run.tcl
  [ "$MODE" = "batch" ] && echo exit >> run.tcl
else
  printf 'run\nexit\n' > run.tcl
fi
GUI_ARGS=()
[ "$MODE" = "gui" ] && GUI_ARGS=(-gui)

XRUN_ARGS=(
  -sv
  -timescale 1ns/1ps
  -cdslib ./cds.lib
  -f files.f
  -top tb_gls
  -access +rwc
  -licqueue
  -nowarn MEMODR
  -nowarn CUVWSP
  -input run.tcl
  -l xrun.log
  "${DEFINES[@]}"
  "${SIM_ARGS[@]}"
  "${PLUSARGS[@]}"
  "${GUI_ARGS[@]}"
)

# ------------------------------------------------------------------------
# 3. Simulate
# ------------------------------------------------------------------------
echo "=== [$TEST] 2/3 xrun ($MODE, $KIND) in $WORK"
echo "    xrun ${XRUN_ARGS[*]}" | tee xrun.cmd
if [ "$MODE" = "gui" ]; then
  xrun "${XRUN_ARGS[@]}"
  RC=$?
else
  timeout "$TIMEOUT" xrun "${XRUN_ARGS[@]}" > /dev/null 2>&1
  RC=$?
  [ $RC -eq 124 ] && echo "$TEST: Test fail (timeout after ${TIMEOUT}s)" >> error.txt
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
if [ "$SDF" -eq 1 ] && [ -f sdf.log ]; then
  echo "--- SDF: $(grep -c '\*W' sdf.log) warning(s) in $WORK/sdf.log"
fi
if [ "$SDF" -eq 1 ]; then
  NTC="$(grep -cE 'Timing violation|\$setup|\$hold|\$width' xrun.log)"
  echo "--- timing check violations in xrun.log: $NTC"
fi
if [ -f error.txt ] && grep -q 'Test ok' error.txt && ! grep -q 'Test fail' error.txt; then
  echo "PASS  $TEST"
  exit 0
fi
[ -f error.txt ] && cat error.txt
echo "FAIL  $TEST  (see $WORK/xrun.log, rc=$RC)"
exit 1
