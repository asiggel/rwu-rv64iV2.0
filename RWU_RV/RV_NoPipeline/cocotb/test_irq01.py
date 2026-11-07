"""
White-box IRQ test (irq01): verifies the CPU's trap-entry / trap-return
hardware directly, without going through any firmware bring-up sequence
and without driving any chip pin.

Rationale: GPIO0's IRQSM/IMSC and ICU0's IMSC/CTRL.GIE are enabled by their
RESET default (as_pack.sv: gpio_irqsm_reg_rst_c, gpio_imsc_reg_rst_c,
icu_imsc_reg_rst_c, icu_ctrl_reg_rst_c). The CPU's MSTATUS.MIE/MIE.MEIE are
0 after reset (privileged spec), so the program starts with the 4
instructions in ENABLE_MEI. After that a real external event only ever has
to set one bit: ICU0's sticky RIS
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
everywhere (after ENABLE_MEI) except a single MRET at the MTVEC reset target (0x7F00), so the
round trip (trap in -> mtvec -> mret -> back to mepc) is exercised without
any hand-written assembler program.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

IMEM_DEPTH  = 8192                    # words; matches as_pack::imemdepth
NOP         = 0x00000013              # addi x0, x0, 0
MRET        = 0x30200073              # mret
MTVEC_RESET = 0x0000000000007F00      # cc_trap_csr MTVEC_RST in asCPUx.sv
MTVEC_WORD  = MTVEC_RESET >> 2        # word index into iram_s = 8128

MCAUSE_MEIP     = (1 << 63) | 11      # machine external interrupt

# mstatus.MIE and mie.MEIE are 0 after reset (privileged spec): enable them
#   lui x1, 1 / addi x1, x1, -2048 / csrrs x0, mie, x1 / csrrsi x0, mstatus, 8
ENABLE_MEI = [0x000010B7, 0x80008093, 0x3040A073, 0x30046073]

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
    for i, w in enumerate(ENABLE_MEI):
        dut.imem.iram_s[i].value = w
    dut.imem.iram_s[MTVEC_WORD].value = MRET

    trap = dut.cpu.trap_csr
    await _reset(dut)
    assert int(trap.mstatus_mie_r.value) == 0, "MSTATUS.MIE must be 0 after reset"
    await _wait_until(dut, lambda: int(trap.mstatus_mie_r.value) == 1,
                       FAST_CLK_CYCLES_PER_POLL, "ENABLE_MEI sets MSTATUS.MIE")
    for _ in range(200):
        await RisingEdge(dut.clk_i)

    # ---- sanity: everything needed is enabled ----
    assert int(dut.icu0.imsc_reg_s.value) & 0x1, "ICU0 GPIO0 source not unmasked by reset"
    assert int(dut.icu0.ctrl_gie_r.value) == 1, "ICU0 GIE not set by reset"
    assert int(trap.mie_r.value) & (1 << 11), "CPU MEIE not set by ENABLE_MEI"
    assert int(dut.cpu.trap_s.value) == 0, "trap_s already asserted before stimulus"

    # ---- stimulus: pretend GPIO0 just latched a pending edge ----
    dut.icu0.ris_reg_s.value = 1

    await _wait_until(dut, lambda: int(dut.cpu.trap_s.value) == 1,
                       FAST_CLK_CYCLES_PER_POLL, "trap_s asserts")

    await _wait_until(dut, lambda: int(dut.cpu.PC_instr_r.value) == MTVEC_RESET,
                       FAST_CLK_CYCLES_PER_POLL, "fetch redirects to mtvec")

    mcause = (int(trap.mcause_int_r.value) << 63) | int(trap.mcause_code_r.value)
    assert mcause == MCAUSE_MEIP, (
        f"mcause=0x{mcause:016x}, expected machine external interrupt "
        f"0x{MCAUSE_MEIP:016x}"
    )
    assert int(trap.mstatus_mie_r.value) == 0, \
        "MSTATUS.MIE must be cleared while the trap is active"

    mepc = int(trap.mepc_r.value)
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
    await _wait_until(dut, lambda: int(dut.cpu.PC_instr_r.value) == mepc,
                       FAST_CLK_CYCLES_PER_POLL, "MRET returns PC to mepc")

    # MRET restores MSTATUS.MIE in the same FETCH0_ST that fetches mepc.
    assert int(trap.mstatus_mie_r.value) == 1, "MSTATUS.MIE not restored after MRET"

    # ---- confirm the return is stable, i.e. no spurious re-trap ----
    for _ in range(800):
        await RisingEdge(dut.clk_i)
        assert int(dut.cpu.trap_s.value) == 0, \
            "spurious re-trap after MRET (pending bit not actually cleared?)"

    dut._log.info("PASS: IRQ trap entry + MRET return verified end-to-end")
