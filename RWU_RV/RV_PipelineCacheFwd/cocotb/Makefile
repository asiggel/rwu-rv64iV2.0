# cocotb + Verilator testbench for RV_PipelineCacheFwd
#
# Unlike RV_NoPipeline (a directly-pokeable as_imem.iram_s array), this
# design fetches instructions through a real I-cache -> AXI4 -> QSPI flash
# path. tb_flash_wrap.sv wraps as_top_mem with a behavioral QSPI flash model
# (copied from tb/tb_rv64i_instr.sv) so cocotb can load a program by poking
# flash_mem_s directly, exactly like RV_NoPipeline/cocotb pokes imem.iram_s.
#
# Usage:
#   make                             # full regression + ISS scoreboard
#   make COCOTB_TEST_MODULES=test_poc

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
TOPLEVEL_LANG        := verilog
SIM                  := verilator
TOPLEVEL             := tb_flash_wrap
COCOTB_TEST_MODULES  ?= test_regression

VENV          := $(abspath venv)
PYTHON        := $(VENV)/bin/python3

COCOTB_HDL_TIMEUNIT      := 1ns
COCOTB_HDL_TIMEPRECISION := 1ps

# ---------------------------------------------------------------------------
# Source files (same set as sim/CMakeLists.txt SOURCES_SV, minus the xsim TB)
# ---------------------------------------------------------------------------
NP_ROOT := $(abspath ../../RV_NoPipeline)
IP_ROOT := $(abspath ../../..)

VERILOG_SOURCES := \
  $(abspath $(NP_ROOT)/src/as_pack.sv)              \
  $(abspath $(NP_ROOT)/src/asRegFile.sv)            \
  $(abspath $(NP_ROOT)/src/asAlu.sv)                \
  $(abspath $(NP_ROOT)/src/asAluBr.sv)              \
  $(abspath $(NP_ROOT)/src/asInstrDecode.sv)        \
  $(abspath $(NP_ROOT)/src/asDecode.sv)             \
  $(abspath $(NP_ROOT)/src/asSBpi.sv)               \
  $(abspath $(IP_ROOT)/ip_jtag/src/tap_fsm.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/ir_cell.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/dr_cell.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/scan_cell.sv)    \
  $(abspath $(IP_ROOT)/ip_jtag/src/by_cell.sv)      \
  $(abspath $(IP_ROOT)/ip_jtag/src/ir_reg.sv)       \
  $(abspath $(IP_ROOT)/ip_jtag/src/dr_reg.sv)       \
  $(abspath $(IP_ROOT)/ip_jtag/src/ir_decode.sv)    \
  $(abspath $(IP_ROOT)/ip_jtag/src/jtag.sv)         \
  $(abspath $(IP_ROOT)/ip_gpio/src/asGpio.sv)       \
  $(abspath $(IP_ROOT)/ip_gpio/src/asGpioTop.sv)    \
  $(abspath $(IP_ROOT)/ip_cgu/src/asCguCore.sv)     \
  $(abspath $(IP_ROOT)/ip_cgu/src/asCguTop.sv)      \
  $(abspath $(IP_ROOT)/ip_fifo/src/as_fifo.sv)      \
  $(abspath $(IP_ROOT)/ip_uart_v2/src/as_uart_top.sv) \
  $(abspath $(IP_ROOT)/ip_qspi/src/as_qspi.sv)      \
  $(abspath $(IP_ROOT)/ip_qspi/src/asQspiTop.sv)    \
  $(abspath $(IP_ROOT)/ip_icu/src/cc_icu.sv)        \
  $(abspath $(IP_ROOT)/ip_icu/src/cc_icu_top.sv)    \
  $(abspath $(IP_ROOT)/ip_icache/src/as_icache_data_ram.sv) \
  $(abspath $(IP_ROOT)/ip_icache/src/as_icache_tag_ram.sv)  \
  $(abspath $(IP_ROOT)/ip_icache/src/as_icache_valid_reg.sv) \
  $(abspath $(IP_ROOT)/ip_icache/src/asICache.sv)   \
  $(abspath $(IP_ROOT)/ip_dcache/src/as_dcache_data_ram.sv) \
  $(abspath $(IP_ROOT)/ip_dcache/src/as_dcache_tag_ram.sv)  \
  $(abspath $(IP_ROOT)/ip_dcache/src/as_dcache_valid_reg.sv) \
  $(abspath $(IP_ROOT)/ip_dcache/src/asDCache.sv)   \
  $(abspath $(IP_ROOT)/ip_scratch/src/as_sram_sp64.sv) \
  $(abspath $(IP_ROOT)/ip_scratch/src/asScratch.sv) \
  $(abspath $(IP_ROOT)/ip_memarb/src/asMemArb.sv)   \
  $(abspath $(IP_ROOT)/ip_memsyst/src/asMemTop.sv)  \
  $(abspath ../src/cc_cpupipefwd.sv)                \
  $(abspath ../src/asTopMem.sv)                     \
  $(abspath tb_flash_wrap.sv)

# ---------------------------------------------------------------------------
# Verilator flags
# ---------------------------------------------------------------------------
EXTRA_ARGS += --sv
EXTRA_ARGS += --public-flat-rw
EXTRA_ARGS += --timing
EXTRA_ARGS += --trace
EXTRA_ARGS += -Wno-WIDTHEXPAND
EXTRA_ARGS += -Wno-WIDTHTRUNC
EXTRA_ARGS += -Wno-INITIALDLY
EXTRA_ARGS += -Wno-CASEINCOMPLETE
EXTRA_ARGS += -Wno-BLKSEQ
EXTRA_ARGS += -Wno-UNSIGNED
EXTRA_ARGS += -Wno-MULTIDRIVEN

PATH := $(VENV)/bin:$(PATH)
export PATH

include $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim
