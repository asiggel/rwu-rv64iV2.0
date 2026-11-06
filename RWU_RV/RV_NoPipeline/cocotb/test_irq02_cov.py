"""
Constrained-random / coverage-driven extension of the deterministic
white-box IRQ test (test_irq01.py).

Where test_irq01 injects the interrupt at one fixed point in the running
instruction stream, this test randomizes *when* the injection happens
(cocotb_coverage.crv.Randomized) and *whether the emulated ISR clears the
ICU pending bit before MRET*, then uses cocotb_coverage.coverage to prove
-- not just assume -- that the sweep actually reached every combination of
"which CPU state was active when the IRQ landed" x "cleared or not". This
is the coincidence-hunting argument from the design discussion: hand-
picking one instant to inject an IRQ is easy to get wrong (or to
unconsciously always pick the "convenient" cycle); coverage bins make the
gaps visible instead of hoping the sweep was broad enough.

Note on stimulus richness: with an all-NOP instruction stream, EXECLD_ST
(asCPUx.sv's load-data state) is structurally unreachable -- NOP never
sets load_pending_s. So the very first instruction is a LW (opcode
LOAD), which is otherwise a no-op for this test (the loaded value is
never used), purely to make all four CPU states reachable for the
coverage sweep. This is itself a small illustration of the same lesson:
coverage closure needs the *stimulus* to be rich enough, not just the
injection timing.

The coverage database is also exported to coverage_irq02.xml/.yml next to
this file (not checked in, see .gitignore) for inspection outside the log.
"""

from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb_coverage import coverage
from cocotb_coverage.crv import Randomized

THIS_DIR = Path(__file__).resolve().parent

IMEM_DEPTH  = 8192                    # words; matches as_pack::imemdepth
NOP         = 0x00000013              # addi x0, x0, 0
LW_X1_0_X0  = 0x00002083              # lw x1, 0(x0) -- makes EXECLD_ST reachable
MRET        = 0x30200073              # mret
MTVEC_RESET = 0x0000000000007F00      # csr_mtvec_r reset value (asCPUx.sv)
MTVEC_WORD  = MTVEC_RESET >> 2        # word index into iram_s = 8128

MSTATUS_MIE_BIT = 3
MCAUSE_MEIP     = (1 << 63) | 11      # machine external interrupt (asCPUx.sv:725)

STATE_NAMES = ["FETCH0", "FETCH1", "EXEC", "EXECLD"]  # asCPUx.sv statetype_t order

NUM_RANDOM_ITERATIONS    = 80
FAST_CLK_CYCLES_PER_POLL = 4000


class IrqStimulus(Randomized):
    """One randomized IRQ-injection scenario.

    delay_cycles       -- how many fast-clock cycles run after reset before
                           the ICU pending bit is forced; sweeps across which
                           CPU FSM state (asCPUx.sv statetype_t) is active
                           when the interrupt lands.
    clear_before_mret  -- whether the emulated ISR clears the ICU pending
                           bit before MRET (correct handling) or leaves it
                           set (must provoke an immediate re-trap, per the
                           documented "direct wire-through" mip behaviour,
                           asCPUx.sv:564).
    """

    def __init__(self):
        Randomized.__init__(self)
        self.delay_cycles      = 4
        self.clear_before_mret = 1
        self.add_rand("delay_cycles", list(range(4, 500)))
        self.add_rand("clear_before_mret", [0, 1])

    def __repr__(self):
        return (f"IrqStimulus(delay_cycles={self.delay_cycles}, "
                f"clear_before_mret={self.clear_before_mret})")


@coverage.CoverPoint(
    "top.irq.cpu_state_at_injection",
    xf=lambda state, cleared: state,
    bins=list(range(4)),
    bins_labels=STATE_NAMES,
)
@coverage.CoverPoint(
    "top.irq.cleared_before_mret",
    xf=lambda state, cleared: cleared,
    bins=[0, 1],
)
@coverage.CoverCross(
    "top.irq.state_x_cleared",
    items=["top.irq.cpu_state_at_injection", "top.irq.cleared_before_mret"],
)
def sample_injection(state, cleared):
    pass


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


def _load_program(dut) -> None:
    for i in range(IMEM_DEPTH):
        dut.imem.iram_s[i].value = NOP
    dut.imem.iram_s[0].value          = LW_X1_0_X0
    dut.imem.iram_s[MTVEC_WORD].value = MRET


async def _run_one(dut, stim: IrqStimulus, iteration: int) -> None:
    """Run one randomized IRQ-injection scenario against a freshly reset DUT."""

    await _reset(dut)
    for _ in range(stim.delay_cycles):
        await RisingEdge(dut.clk_i)

    tag = f"[iter {iteration}] {stim}"

    assert int(dut.cpu.csr_mstatus_r.value) & (1 << MSTATUS_MIE_BIT), \
        f"{tag}: MSTATUS.MIE not set before stimulus"
    assert int(dut.cpu.trap_taken_s.value) == 0, \
        f"{tag}: trap_taken_s already asserted before stimulus"

    state_at_injection = int(dut.cpu.state_s.value)
    sample_injection(state_at_injection, stim.clear_before_mret)

    dut.icu0.ris_reg_s.value = 1

    await _wait_until(dut, lambda: int(dut.cpu.trap_taken_s.value) == 1,
                       FAST_CLK_CYCLES_PER_POLL, f"{tag}: trap_taken_s asserts")
    await _wait_until(dut, lambda: int(dut.cpu.PC_s.value) == MTVEC_RESET,
                       FAST_CLK_CYCLES_PER_POLL, f"{tag}: PC_s redirects to mtvec")

    mcause = int(dut.cpu.csr_mcause_r.value)
    assert mcause == MCAUSE_MEIP, f"{tag}: mcause=0x{mcause:016x}"
    assert int(dut.cpu.csr_mstatus_r.value) & (1 << MSTATUS_MIE_BIT) == 0, \
        f"{tag}: MSTATUS.MIE must be cleared while the trap is active"

    mepc = int(dut.cpu.csr_mepc_r.value)

    if stim.clear_before_mret:
        dut.icu0.ris_reg_s.value = 0   # the ICR write a real ISR would do

    await _wait_until(dut, lambda: int(dut.cpu.PC_s.value) == mepc,
                       FAST_CLK_CYCLES_PER_POLL, f"{tag}: MRET returns PC to mepc")
    await _wait_until(dut, lambda: int(dut.cpu.csr_mstatus_r.value) & (1 << MSTATUS_MIE_BIT),
                       FAST_CLK_CYCLES_PER_POLL, f"{tag}: MSTATUS.MIE restored after MRET")

    if stim.clear_before_mret:
        for _ in range(300):
            await RisingEdge(dut.clk_i)
            assert int(dut.cpu.trap_taken_s.value) == 0, \
                f"{tag}: spurious re-trap despite cleared pending bit"
    else:
        # Pending bit deliberately left set: hardware must re-trap almost
        # immediately (mip[11] is a direct wire-through of the ICU output,
        # not a one-shot pulse -- see asCPUx.sv:564).
        await _wait_until(dut, lambda: int(dut.cpu.trap_taken_s.value) == 1,
                           FAST_CLK_CYCLES_PER_POLL,
                           f"{tag}: expected immediate re-trap (pending bit left set)")


@cocotb.test()
async def irq_random_test(dut):
    """cocotb-coverage constrained-random sweep of IRQ-injection timing."""

    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())   # 100 MHz
    cocotb.start_soon(Clock(dut.tck_i, 100, unit="ns").start())  # 10 MHz JTAG
    dut.tms_i.value = 0
    dut.tdi_i.value = 0

    stim = IrqStimulus()
    for iteration in range(NUM_RANDOM_ITERATIONS):
        _load_program(dut)

        stim.randomize()
        dut._log.info(f"iteration {iteration}: {stim}")

        await _run_one(dut, stim, iteration)

    coverage.coverage_db.report_coverage(dut._log.info, bins=True)

    xml_path = THIS_DIR / "coverage_irq02.xml"
    yml_path = THIS_DIR / "coverage_irq02.yml"
    coverage.coverage_db.export_to_xml(filename=str(xml_path))
    coverage.coverage_db.export_to_yaml(filename=str(yml_path))
    dut._log.info(f"coverage exported: {xml_path}, {yml_path}")

    cross = coverage.coverage_db["top.irq.state_x_cleared"]
    assert cross.coverage == cross.size, (
        f"coverage not closed after {NUM_RANDOM_ITERATIONS} iterations: "
        f"{cross.coverage}/{cross.size} state x cleared_before_mret bins hit"
    )

    dut._log.info(f"PASS: {NUM_RANDOM_ITERATIONS} randomized IRQ scenarios, "
                   f"full state x cleared_before_mret coverage closed")
