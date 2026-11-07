#!/usr/bin/env python3
"""
Standalone cocotb runner for the randomized/coverage-driven IRQ test
(test_irq02_cov.py), the cocotb-coverage extension of test_irq01.py.

    python3 test_runner_irq02_cov.py

from this directory (cocotb/). Reuses the same Verilator build as
test_runner_irq01.py (identical DUT, so the compiled model is shared) --
if sim_build_irq01/ does not exist yet, it is built here.
"""

import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

THIS_DIR = Path(__file__).resolve().parent
SRC_DIR  = THIS_DIR.parent            # RV_NoPipeline/
IP_ROOT  = SRC_DIR.parent.parent      # asgithub/

VERILOG_SOURCES = [
    SRC_DIR / "src" / "as_pack.sv",
    IP_ROOT / "ip_dmem" / "src" / "asDMemBack.sv",
    IP_ROOT / "ip_dmem" / "src" / "asDMemFront.sv",
    IP_ROOT / "ip_dmem" / "src" / "asDMemCore.sv",
    IP_ROOT / "ip_dmem" / "src" / "asDMem.sv",
    IP_ROOT / "ip_dmem" / "src" / "asDMemTop.sv",
    SRC_DIR / "src" / "asIMem.sv",
    SRC_DIR / "src" / "asRegFile.sv",
    SRC_DIR / "src" / "asAlu.sv",
    SRC_DIR / "src" / "asAluBr.sv",
    SRC_DIR / "src" / "asInstrDecode.sv",
    IP_ROOT / "ip_jtag" / "src" / "tap_fsm.sv",
    IP_ROOT / "ip_jtag" / "src" / "ir_cell.sv",
    IP_ROOT / "ip_jtag" / "src" / "dr_cell.sv",
    IP_ROOT / "ip_jtag" / "src" / "scan_cell.sv",
    IP_ROOT / "ip_jtag" / "src" / "by_cell.sv",
    IP_ROOT / "ip_jtag" / "src" / "ir_reg.sv",
    IP_ROOT / "ip_jtag" / "src" / "dr_reg.sv",
    IP_ROOT / "ip_jtag" / "src" / "ir_decode.sv",
    IP_ROOT / "ip_jtag" / "src" / "jtag.sv",
    SRC_DIR / "src" / "asMBpi.sv",
    SRC_DIR / "src" / "asSBpi.sv",
    IP_ROOT / "ip_gpio" / "src" / "asGpio.sv",
    IP_ROOT / "ip_irqper" / "src" / "as_irq_peripheral.sv",
    IP_ROOT / "ip_gpio" / "src" / "asGpioTop.sv",
    IP_ROOT / "ip_trapcsr" / "src" / "cc_trap_csr.sv",
    SRC_DIR / "src" / "asCPUx.sv",
    SRC_DIR / "src" / "asDecode.sv",
    IP_ROOT / "ip_cgu" / "src" / "asCguCore.sv",
    IP_ROOT / "ip_cgu" / "src" / "asCguTop.sv",
    IP_ROOT / "ip_fifo" / "src" / "as_fifo.sv",
    IP_ROOT / "ip_uart_v2" / "src" / "as_uart_top.sv",
    IP_ROOT / "ip_icu" / "src" / "cc_icu.sv",
    IP_ROOT / "ip_icu" / "src" / "cc_icu_top.sv",
    SRC_DIR / "src" / "asTopMem.sv",
]

BUILD_ARGS = [
    "--sv",
    "--public-flat-rw",
    "--trace",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-INITIALDLY",
    "-Wno-CASEINCOMPLETE",
    "-Wno-BLKSEQ",
]


def main() -> None:
    for src in VERILOG_SOURCES:
        if not src.exists():
            sys.exit(f"missing source file: {src}")

    build_dir = THIS_DIR / "sim_build_irq01"   # shared with test_runner_irq01.py

    runner = get_runner("verilator")
    runner.build(
        verilog_sources=VERILOG_SOURCES,
        hdl_toplevel="as_top_mem",
        build_args=BUILD_ARGS,
        build_dir=build_dir,
        timescale=("1ns", "1ps"),
        waves=True,
    )
    runner.test(
        test_module="test_irq02_cov",
        hdl_toplevel="as_top_mem",
        build_dir=build_dir,
        test_dir=THIS_DIR,
        waves=True,
    )


if __name__ == "__main__":
    main()
