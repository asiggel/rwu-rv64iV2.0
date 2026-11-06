"""
White-box IRQ test (irq01): verifies the CPU's trap-entry / trap-return
hardware directly, without going through any firmware bring-up sequence
and without driving any chip pin.

Rationale: GPIO0's IRQSM/IMSC, ICU0's IMSC/CTRL.GIE and the CPU's
MSTATUS.MIE/MIE.MEIE are all enabled by their RESET default (as_pack.sv:
gpio_irqsm_reg_rst_c, gpio_imsc_reg_rst_c, icu_imsc_reg_rst_c,
icu_ctrl_reg_rst_c; asCPUx.sv: csr_mstatus_r/csr_mie_r reset values), so a
real external event only ever has to set one bit: ICU0's sticky RIS
register for the GPIO0 source. This test pokes that register directly
(cc_icu_top.sv's ris_reg_s, a plain always_ff register, not a
continuously-driven net) instead of toggling the GPIO0 pin -- Verilator's
VPI does not expose the `gpio_io` inout port at all (confirmed: it is
simply absent from `dut`'s child list, unlike every non-tristate signal),
so the pad itself is not a usable injection point with this toolchain.
Poking the ICU's pending-bit register is both the most direct level at
which "an external interrupt has occurred" can be expressed, and the one
piece of state a peripheral genuinely owns (GPIO0's own edge-detector and
IRQSM masking logic are a separate, GPIO0-local test concern, see
ip_gpio/tb).

The "ISR" is reduced to the theoretical minimum: I-Mem is filled with NOP
everywhere except a single MRET at the MTVEC reset target (0x7F00), so the
round trip (trap in -> mtvec -> mret -> back to mepc) is exercised without
any hand-written assembler program.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

IMEM_DEPTH  = 8192                    # words; matches as_pack::imemdepth
NOP         = 0x00000013              # addi x0, x0, 0
MRET        = 0x30200073              # mret
MTVEC_RESET = 0x0000000000007F00      # csr_mtvec_r reset value (asCPUx.sv)
MTVEC_WORD  = MTVEC_RESET >> 2        # word index into iram_s = 8128

MSTATUS_MIE_BIT = 3
MCAUSE_MEIP     = (1 << 63) | 11      # machine external interrupt (asCPUx.sv:725)

FAST_CLK_CYCLES_PER_POLL = 4000       # generous vs. clk_core_div=80 slow-clock ratio


async def _reset(dut) -> None:
    dut.rst_i.value  = 1
    dut.trst_i.value = 1
    dut.tms_i.value  = 0
    dut.tdi_i.value  = 0
    for _ in range(20):
        await RisingEdge(dut.clk_i)
    dut.rst_i.value  = 0
    dut.trst_i.value = 0


async def _wait_until(dut, predicate, cycles, what: str):
    for _ in range(cycles):
        await RisingEdge(dut.clk_i)
        if predicate():
            return
    assert False, f"timeout waiting for: {what}"


@cocotb.test()
async def irq_whitebox_test(dut):
    """Force ICU0's GPIO0 pending bit, verify trap entry/return purely via internal CSRs."""

    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())   # 100 MHz
    cocotb.start_soon(Clock(dut.tck_i, 100, unit="ns").start())  # 10 MHz JTAG

    # ---- program: NOP everywhere, MRET at the mtvec target ----
    for i in range(IMEM_DEPTH):
        dut.imem.iram_s[i].value = NOP
    dut.imem.iram_s[MTVEC_WORD].value = MRET

    await _reset(dut)
    for _ in range(200):
        await RisingEdge(dut.clk_i)

    # ---- sanity: everything needed is already enabled by reset default ----
    assert int(dut.icu0.imsc_reg_s.value) & 0x1, "ICU0 GPIO0 source not unmasked by reset"
    assert int(dut.icu0.ctrl_gie_r.value) == 1, "ICU0 GIE not set by reset"
    assert int(dut.cpu.csr_mie_r.value) & (1 << 11), "CPU MEIE not set by reset"
    assert int(dut.cpu.csr_mstatus_r.value) & (1 << MSTATUS_MIE_BIT), \
        "MSTATUS.MIE not set before stimulus (expected reset default)"
    assert int(dut.cpu.trap_taken_s.value) == 0, \
        "trap_taken_s already asserted before stimulus"

    # ---- stimulus: pretend GPIO0 just latched a pending edge ----
    dut.icu0.ris_reg_s.value = 1

    await _wait_until(dut, lambda: int(dut.cpu.trap_taken_s.value) == 1,
                       FAST_CLK_CYCLES_PER_POLL, "trap_taken_s asserts")

    await _wait_until(dut, lambda: int(dut.cpu.PC_s.value) == MTVEC_RESET,
                       FAST_CLK_CYCLES_PER_POLL, "PC_s redirects to mtvec")

    mcause = int(dut.cpu.csr_mcause_r.value)
    assert mcause == MCAUSE_MEIP, (
        f"mcause=0x{mcause:016x}, expected machine external interrupt "
        f"0x{MCAUSE_MEIP:016x}"
    )
    assert int(dut.cpu.csr_mstatus_r.value) & (1 << MSTATUS_MIE_BIT) == 0, \
        "MSTATUS.MIE must be cleared while the trap is active"

    mepc = int(dut.cpu.csr_mepc_r.value)
    dut._log.info(f"trap entry OK: mepc=0x{mepc:016x}  mcause=0x{mcause:016x}")

    # ---- emulate the ICR write a real ISR would do before MRET ----
    # We forced ris_reg_s directly (bypassing the GPIO0 edge detector), so
    # nothing ever clears it automatically the way a real ICR write would.
    # Leaving it set is not a CPU bug -- it faithfully reproduces "ISR forgot
    # to clear the pending bit", i.e. an immediate re-trap after MRET. Since
    # this test's "ISR" has no instructions to do the clear itself, clear it
    # here to isolate the trap-entry/-return round trip from that separate
    # (and equally valid, but different) scenario.
    dut.icu0.ris_reg_s.value = 0

    # ---- the "ISR" (a single MRET) returns; verify the round trip ----
    await _wait_until(dut, lambda: int(dut.cpu.PC_s.value) == mepc,
                       FAST_CLK_CYCLES_PER_POLL, "MRET returns PC to mepc")

    # MSTATUS.MIE restore is gated on the MRET reaching EXEC_ST via ir_s,
    # which lags the PC_s redirect above by a few pipeline cycles (PC_s is
    # updated one fetch0 cycle ahead of the instruction actually being
    # decoded/executed) -- so poll for it separately instead of checking it
    # in the same instant as the PC_s match.
    await _wait_until(dut, lambda: int(dut.cpu.csr_mstatus_r.value) & (1 << MSTATUS_MIE_BIT),
                       FAST_CLK_CYCLES_PER_POLL, "MSTATUS.MIE restored after MRET")

    # ---- confirm the return is stable, i.e. no spurious re-trap ----
    for _ in range(800):
        await RisingEdge(dut.clk_i)
        assert int(dut.cpu.trap_taken_s.value) == 0, \
            "spurious re-trap after MRET (pending bit not actually cleared?)"

    dut._log.info("PASS: IRQ trap entry + MRET return verified end-to-end")
