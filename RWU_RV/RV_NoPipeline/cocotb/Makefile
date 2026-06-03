# cocotb + Verilator testbench for RV_NoPipeline
#
# Usage:
#   make                             # run PoC smoke test (instr06addi, expected=255)
#   make MEMFILE=../build_xsim/instr30beq/asm/rv64i.mem EXPECTED=30
#
# The RISC-V binary is loaded via $readmemh("riscvtest.mem") in asIMem.sv;
# we copy MEMFILE to $(SIM_BUILD)/riscvtest.mem before simulation starts.

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
TOPLEVEL_LANG        := verilog
SIM                  := verilator
TOPLEVEL             := as_top_mem
# Default: full regression + ISS scoreboard.  Override for the smoke test:
#   make COCOTB_TEST_MODULES=test_poc
COCOTB_TEST_MODULES  ?= test_regression

VENV          := $(abspath venv)
PYTHON        := $(VENV)/bin/python3

COCOTB_HDL_TIMEUNIT      := 1ns
COCOTB_HDL_TIMEPRECISION := 1ps

# ---------------------------------------------------------------------------
# Source files (same set as xsim regression)
# ---------------------------------------------------------------------------
IP_ROOT := $(abspath ../../..)

VERILOG_SOURCES := \
  $(abspath ../src/as_pack.sv)             \
  $(abspath $(IP_ROOT)/ip_dmem/src/asDMemBack.sv)   \
  $(abspath $(IP_ROOT)/ip_dmem/src/asDMemFront.sv)  \
  $(abspath $(IP_ROOT)/ip_dmem/src/asDMemCore.sv)   \
  $(abspath $(IP_ROOT)/ip_dmem/src/asDMem.sv)       \
  $(abspath $(IP_ROOT)/ip_dmem/src/asDMemTop.sv)    \
  $(abspath ../src/asIMem.sv)              \
  $(abspath ../src/asRegFile.sv)           \
  $(abspath ../src/asAlu.sv)               \
  $(abspath ../src/asAluBr.sv)             \
  $(abspath ../src/asInstrDecode.sv)       \
  $(abspath $(IP_ROOT)/ip_jtag/src/tap_fsm.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/ir_cell.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/dr_cell.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/scan_cell.sv)    \
  $(abspath $(IP_ROOT)/ip_jtag/src/by_cell.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/ir_reg.sv)       \
  $(abspath $(IP_ROOT)/ip_jtag/src/dr_reg.sv)       \
  $(abspath $(IP_ROOT)/ip_jtag/src/ir_decode.sv)    \
  $(abspath $(IP_ROOT)/ip_jtag/src/jtag.sv)         \
  $(abspath ../src/asMBpi.sv)              \
  $(abspath ../src/asSBpi.sv)              \
  $(abspath $(IP_ROOT)/ip_gpio/src/asGpio.sv)       \
  $(abspath $(IP_ROOT)/ip_gpio/src/asGpioTop.sv)    \
  $(abspath ../src/asCPUx.sv)              \
  $(abspath ../src/asDecode.sv)            \
  $(abspath $(IP_ROOT)/ip_cgu/src/asCguCore.sv)     \
  $(abspath $(IP_ROOT)/ip_cgu/src/asCguTop.sv)      \
  $(abspath ../src/asTopMem.sv)

# ---------------------------------------------------------------------------
# Verilator flags
# ---------------------------------------------------------------------------
EXTRA_ARGS += --sv
EXTRA_ARGS += --public-flat-rw
EXTRA_ARGS += --trace
EXTRA_ARGS += -Wno-WIDTHEXPAND
EXTRA_ARGS += -Wno-WIDTHTRUNC
EXTRA_ARGS += -Wno-INITIALDLY
EXTRA_ARGS += -Wno-CASEINCOMPLETE
EXTRA_ARGS += -Wno-BLKSEQ

# Pass expected GPIO value to the Python test
EXPECTED ?= 255
PLUSARGS += +expected=$(EXPECTED)

# ---------------------------------------------------------------------------
# Test program (.mem file loaded by asIMem via $readmemh)
# ---------------------------------------------------------------------------
MEMFILE   ?= $(abspath programs/instr06addi.mem)
SIM_BUILD ?= sim_build

# ---------------------------------------------------------------------------
# Include cocotb rules (defines $(COCOTB_RESULTS_FILE) and the sim target)
# ---------------------------------------------------------------------------
PATH := $(VENV)/bin:$(PATH)
export PATH

include $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim

# asIMem.sv uses $readmemh("riscvtest.mem") with a bare filename, so the
# simulation binary looks in CWD (= this directory, cocotb/).
$(COCOTB_RESULTS_FILE): riscvtest.mem

riscvtest.mem: $(MEMFILE)
	@cp $< $@
	@echo "  [cocotb] loaded $<"

.PHONY: clean_mem
clean_mem:
	@rm -f riscvtest.mem
