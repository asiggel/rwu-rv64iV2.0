"""
PoC smoke test: Verilator + cocotb + as_top_mem run together.

Drives clk/rst, waits for the CPU to write to GPIO (signalled by cs_o=1),
reads the GPIO data register, and asserts the expected value was written.

Configured via plusargs:
  +expected=<int>   GPIO byte value that signals test success (default 255)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


def _plusarg_int(name: str, default: int) -> int:
    """Read a +name=value plusarg; return default if absent."""
    import sys
    prefix = f"+{name}="
    for arg in sys.argv:
        if arg.startswith(prefix):
            return int(arg[len(prefix):])
    return default


@cocotb.test()
async def smoke_test(dut):
    """Boot CPU, run program, verify GPIO output matches +expected value."""

    expected = _plusarg_int("expected", 255)

    # -----------------------------------------------------------------------
    # Clocks
    # -----------------------------------------------------------------------
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())   # 100 MHz
    cocotb.start_soon(Clock(dut.tck_i, 100, unit="ns").start())  # 10 MHz JTAG

    # -----------------------------------------------------------------------
    # Reset (active-high; hold for 20 clock cycles)
    # -----------------------------------------------------------------------
    dut.rst_i.value  = 1
    dut.trst_i.value = 1
    dut.tms_i.value  = 0
    dut.tdi_i.value  = 0

    for _ in range(20):
        await RisingEdge(dut.clk_i)

    dut.rst_i.value  = 0
    dut.trst_i.value = 0

    # -----------------------------------------------------------------------
    # Run until cs_o pulses with the expected GPIO byte (max 20 CS events).
    # cs_o is registered on the slow core clock (clk_i / 80), so it stays high
    # for ~80 fast-clock cycles.  Track transitions to count each pulse once.
    # -----------------------------------------------------------------------
    cs_count = 0
    prev_cs  = 0
    for _ in range(200_000):
        await RisingEdge(dut.clk_i)
        curr_cs = int(dut.cs_o.value)

        if prev_cs == 0 and curr_cs == 1:   # rising edge only
            cs_count += 1
            # data_reg_s is 64-bit; the GPIO byte is in bits [7:0]
            gpio_val = int(dut.asGpio.data_reg_s.value) & 0xFF
            dut._log.info(f"CS #{cs_count}: gpio=0x{gpio_val:02x}  expected=0x{expected:02x}")

            if gpio_val == expected:
                dut._log.info("PASSED")
                return

            assert cs_count < 20, (
                f"gpio=0x{gpio_val:02x} never matched expected=0x{expected:02x} "
                f"after {cs_count} CS pulses"
            )

        prev_cs = curr_cs

    raise TimeoutError(f"Timeout after 200 000 cycles — no match for expected=0x{expected:02x}")
