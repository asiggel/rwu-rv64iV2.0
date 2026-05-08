import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

PASS_ADDR = 0x1000
FAIL_ADDR = 0x1008

@cocotb.test()
async def test_add(dut):

    # Core Clock
    cocotb.start_soon(
        Clock(dut.clk_i, 10, unit="ns").start()
    )

    # JTAG clock optional
    cocotb.start_soon(
        Clock(dut.tck_i, 100, unit="ns").start()
    )

    # Reset
    dut.rst_i.value = 1
    dut.trst_i.value = 1

    dut.tms_i.value = 0
    dut.tdi_i.value = 0

    for _ in range(20):
        await RisingEdge(dut.clk_i)

    dut.rst_i.value = 0
    dut.trst_i.value = 0

    # Simulation
    for cycle in range(5000):

        await RisingEdge(dut.clk_i)

        we   = int(dut.wbdwe_s.value)
        stb  = int(dut.wbdstDMem_s.value)

        if we and stb:

            addr = int(dut.dBusAddr_s.value)
            data = int(dut.dBusDataWr_s.value)

            print(f"WRITE addr=0x{addr:x} data=0x{data:x}")

            if addr == PASS_ADDR:
                cocotb.log.info("TEST PASSED")
                return

            if addr == FAIL_ADDR:
                raise Exception("TEST FAILED")

    raise Exception("TIMEOUT")
