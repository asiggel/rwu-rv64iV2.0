"""
Directed trap / interrupt tests (precise traps, RISC-V privileged spec, M-mode).

Shared by RV_NoPipeline/cocotb/test_traps.py and
RV_PipelineCacheFwd/cocotb/test_traps.py: each core gets a small adapter
(class NoPipeline / Pipeline) that says where its memory, registers and
cc_trap_csr live; the test functions below are core-independent.

What is checked (the regression with the ISS cannot see it, because its
programs never get interrupted):
  - an interrupt never loses or duplicates an instruction, also directly
    before/after taken jumps and around loads/stores (end values of counters)
  - mepc of every interrupt = first instruction not yet executed
  - a misaligned/illegal/ecall instruction traps with mepc = its own address,
    correct mcause/mtval, and leaves registers and memory untouched
  - vectored mtvec, WFI, JALR with rd = rs1, M-mode CSR reads
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from rvenc import *

MTVEC = 0x7F00            # cc_trap_csr MTVEC_RST in both cores
DMEM  = 0x100             # data address for load/store tests
MCAUSE_INT = 1 << 63

# mie.MEIE = 1, mstatus.MIE = 1 (both are 0 after reset)
ENABLE_MEI = li(1, 0x800) + [csrrs(0, CSR_MIE, 1), csrrsi(0, CSR_MSTATUS, 8)]


class Core:
    """Adapter base class: one subclass per CPU variant."""
    imem_words = 0
    irq_gap    = (0, 0)       # random distance between interrupts [clk_i cycles]
    max_cycles = 0            # time-out for one wait

    def __init__(self, dut):
        self.dut = dut

    # --- variant-specific -------------------------------------------------
    def imem(self):  raise NotImplementedError
    def cpu(self):   raise NotImplementedError
    def icu(self):   raise NotImplementedError
    def trap(self) -> bool: raise NotImplementedError
    def pc(self) -> int:    raise NotImplementedError
    def extra_inputs(self): pass

    # --- common -------------------------------------------------------------
    def x(self, i: int) -> int:
        return int(self.cpu().regfile.regfile_s[i].value)

    def csr(self, name: str) -> int:
        t = self.cpu().trap_csr
        if name == "mcause":
            return (int(t.mcause_int_r.value) << 63) | int(t.mcause_code_r.value)
        if name == "mstatus":
            return 0x1800 | (int(t.mstatus_mpie_r.value) << 7) | (int(t.mstatus_mie_r.value) << 3)
        return int(getattr(t, f"{name}_r").value)

    def irq(self, level: int) -> None:
        self.icu().ris_reg_s.value = level


class NoPipeline(Core):
    imem_words = 8192
    irq_gap    = (50, 700)
    max_cycles = 400_000

    def imem(self):  return self.dut.imem.iram_s
    def cpu(self):   return self.dut.cpu
    def icu(self):   return self.dut.icu0
    def trap(self):  return bool(int(self.dut.cpu.trap_s.value))
    def pc(self):    return int(self.dut.cpu.PC_instr_r.value)


class Pipeline(Core):
    # instructions come from the QSPI flash model through the I-cache: slow
    imem_words = 16384
    irq_gap    = (20_000, 120_000)
    max_cycles = 3_000_000

    def imem(self):  return self.dut.flash_mem_s
    def cpu(self):   return self.dut.DUT.cpu
    def icu(self):   return self.dut.DUT.icu0
    def trap(self):  return bool(int(self.dut.DUT.cpu.wb_trap_taken_s.value))
    def pc(self):    return int(self.dut.DUT.cpu.mem_wb_pc_r.value)
    def extra_inputs(self): self.dut.uart0_rx_i.value = 1


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
async def start(core: Core, prog: list[int], isr: dict[int, int] | None = None) -> None:
    dut = core.dut
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.tck_i, 100, unit="ns").start())
    mem = core.imem()
    for i in range(core.imem_words):
        mem[i].value = NOP
    for i, w in enumerate(prog):
        mem[i].value = w
    for addr, w in (isr if isr is not None else {MTVEC: MRET}).items():
        mem[addr >> 2].value = w
    core.extra_inputs()
    core.irq(0)
    dut.rst_i.value = 1
    dut.trst_i.value = 1
    dut.tms_i.value = 0
    dut.tdi_i.value = 0
    await ClockCycles(dut.clk_i, 20)
    dut.rst_i.value = 0
    dut.trst_i.value = 0


async def wait_for(core: Core, cond, what: str) -> None:
    for _ in range(core.max_cycles):
        if cond():
            return
        await RisingEdge(core.dut.clk_i)
    assert False, f"time-out waiting for {what} (pc={core.pc():#x})"


async def wait_pc(core: Core, addr: int) -> None:
    await wait_for(core, lambda: core.pc() == addr, f"pc == {addr:#x}")


async def first_trap(core: Core, prog: list[int], isr=None, vector: int = MTVEC):
    await start(core, prog, isr)
    await wait_pc(core, vector)
    return core.csr("mepc"), core.csr("mcause"), core.csr("mtval")


async def run_with_irqs(core: Core, prog: list[int], spin: int, seed: int):
    """Interrupt the program at random points until it reaches *spin*.
    Returns [(mepc, x5)] of every interrupt."""
    await start(core, prog)
    rnd = random.Random(seed)
    clk = core.dut.clk_i
    traps = []
    budget = 0
    while core.pc() != spin:
        gap = rnd.randint(*core.irq_gap)
        await ClockCycles(clk, gap)
        budget += gap
        assert budget < 40 * core.max_cycles, f"program does not finish (pc={core.pc():#x})"
        if core.pc() == spin:
            break
        core.irq(1)
        await wait_for(core, core.trap, "interrupt trap")
        await wait_for(core, lambda: not core.trap(), "end of trap entry")
        await ClockCycles(clk, 4)
        traps.append((core.csr("mepc"), core.x(5)))
        core.irq(0)
        await wait_for(core, lambda: core.csr("mstatus") & 0x8 and core.pc() != MTVEC, "MRET")
    await ClockCycles(clk, 2000)
    core.dut._log.info(f"{len(traps)} interrupts, x5 = {core.x(5)}")
    return traps


def straight_program():
    """x5 counts executed addi's; jal/beq each skip a +100."""
    p = ENABLE_MEI + [addi(5, 0, 0)]
    first = 4 * len(p)
    p += [addi(5, 5, 1)] * 200
    skips = [4 * len(p) + 4]
    p += [jal(6, 8), addi(5, 5, 100)]
    p += [addi(5, 5, 1)] * 20
    skips.append(4 * len(p) + 4)
    p += [beq(0, 0, 8), addi(5, 5, 100)]
    p += [addi(5, 5, 1)] * 20
    spin = 4 * len(p)
    p += [jal(0, 0)]
    return p, 240, first, skips, spin


def jump_program(n: int = 60):
    """Every third instruction is a taken jal/beq; no skipped +100 may run."""
    p = ENABLE_MEI + [addi(5, 0, 0)]
    skips = []
    for _ in range(n):
        base = 4 * len(p)
        skips += [base + 8, base + 20]
        p += [addi(5, 5, 1), jal(0, 8), addi(5, 5, 100),
              addi(5, 5, 1), beq(0, 0, 8), addi(5, 5, 100)]
    spin = 4 * len(p)
    p += [jal(0, 0)]
    return p, 2 * n, skips, spin


# ---------------------------------------------------------------------------
# tests (called by the per-core test_traps.py)
# ---------------------------------------------------------------------------
async def irq_straight(core: Core, seed: int = 1):
    prog, expect, first, skips, spin = straight_program()
    traps = await run_with_irqs(core, prog, spin, seed)
    assert traps, "no interrupt was taken"
    for mepc, v in traps:
        assert mepc not in skips, f"mepc {mepc:#x} points to a skipped instruction"
        if 1 <= v < 200:
            assert mepc == first + 4 * v, \
                f"x5={v}: mepc={mepc:#x}, expected {first + 4 * v:#x} (next unexecuted)"
    assert core.x(5) == expect, f"x5 = {core.x(5)}, expected {expect}"


async def irq_jumps(core: Core, seed: int = 2):
    prog, expect, skips, spin = jump_program()
    traps = await run_with_irqs(core, prog, spin, seed)
    assert traps, "no interrupt was taken"
    for mepc, _ in traps:
        assert mepc not in skips, f"mepc {mepc:#x} points to a skipped instruction"
    assert core.x(5) == expect, f"x5 = {core.x(5)}, expected {expect}"


async def irq_memory(core: Core, seed: int = 3, n: int = 40):
    """Read-modify-write of a memory counter: an interrupted load/store must
    neither be lost nor repeated."""
    p = ENABLE_MEI + [addi(8, 0, DMEM), sd(0, 8, 0)]
    p += [ld(6, 8, 0), addi(6, 6, 1), sd(6, 8, 0)] * n
    p += [ld(7, 8, 0)]
    spin = 4 * len(p)
    p += [jal(0, 0)]
    traps = await run_with_irqs(core, prog=p, spin=spin, seed=seed)
    assert traps, "no interrupt was taken"
    assert core.x(7) == n, f"memory counter = {core.x(7)}, expected {n}"


async def misaligned_store(core: Core):
    prog = [addi(7, 0, 0x55), addi(8, 0, DMEM), sd(0, 8, 0), sd(0, 8, 8),
            sd(7, 8, 1),                       # 0x10: must trap, must not write
            addi(9, 0, 1), jal(0, 0)]
    isr = {MTVEC: ld(10, 8, 0), MTVEC + 4: ld(11, 8, 8), MTVEC + 8: jal(0, 0)}
    mepc, mcause, mtval = await first_trap(core, prog, isr)
    assert (mepc, mcause, mtval) == (0x10, 6, DMEM + 1), (hex(mepc), mcause, hex(mtval))
    await wait_pc(core, MTVEC + 8)
    await ClockCycles(core.dut.clk_i, 400)
    assert (core.x(10), core.x(11)) == (0, 0), "misaligned store has written memory"
    assert core.x(9) == 0


async def misaligned_load(core: Core):
    prog = [addi(10, 0, 0x77), addi(8, 0, DMEM), ld(10, 8, 1), addi(9, 0, 1), jal(0, 0)]
    mepc, mcause, mtval = await first_trap(core, prog)
    assert (mepc, mcause, mtval) == (0x8, 4, DMEM + 1), (hex(mepc), mcause, hex(mtval))
    assert core.x(10) == 0x77, "misaligned load has written rd"
    assert core.x(9) == 0


async def misaligned_jump(core: Core):
    prog = [addi(1, 0, 0x5A), jalr(1, 0, 2), addi(9, 0, 1), jal(0, 0)]
    mepc, mcause, mtval = await first_trap(core, prog)
    assert (mepc, mcause, mtval) == (0x4, 0, 0x2), (hex(mepc), mcause, hex(mtval))
    assert core.x(1) == 0x5A, "trapping jalr has written its link register"


async def illegal_instr(core: Core):
    prog = [addi(9, 0, 1), 0xFFFFFFFF, addi(9, 0, 2), jal(0, 0)]
    mepc, mcause, mtval = await first_trap(core, prog)
    assert (mepc, mcause, mtval) == (0x4, 2, 0xFFFFFFFF), (hex(mepc), mcause, hex(mtval))
    assert core.x(9) == 1


async def illegal_csr(core: Core):
    bad = csrrw(5, CSR_MHARTID, 1)              # write to a read-only CSR
    prog = [addi(5, 0, 0x33), bad, addi(9, 0, 2), jal(0, 0)]
    mepc, mcause, mtval = await first_trap(core, prog)
    assert (mepc, mcause, mtval) == (0x4, 2, bad), (hex(mepc), mcause, hex(mtval))
    assert core.x(5) == 0x33, "illegal CSR instruction has written rd"


async def ecall(core: Core):
    prog = [addi(9, 0, 1), ECALL, addi(9, 0, 2), jal(0, 0)]
    mepc, mcause, _ = await first_trap(core, prog)
    assert (mepc, mcause) == (0x4, 11)


async def ebreak(core: Core):
    prog = [addi(9, 0, 1), EBREAK, addi(9, 0, 2), jal(0, 0)]
    mepc, mcause, _ = await first_trap(core, prog)
    assert (mepc, mcause) == (0x4, 3)


async def jalr_link(core: Core):
    """jalr x1, 0(x1): the target must use the OLD x1."""
    prog = [addi(1, 0, 16), jalr(1, 1, 0), addi(9, 0, 99), jal(0, 0),
            addi(9, 0, 7), jal(0, 0)]
    await start(core, prog)
    await wait_pc(core, 20)
    await ClockCycles(core.dut.clk_i, 400)
    assert (core.x(9), core.x(1)) == (7, 8), (core.x(9), core.x(1))


async def csr_reads(core: Core):
    prog = [csrrs(10, CSR_MHARTID, 0), csrrs(11, CSR_MISA, 0),
            csrrwi(0, CSR_MSCRATCH, 21), csrrs(12, CSR_MSCRATCH, 0),
            csrrs(13, CSR_MINSTRET, 0), NOP, csrrs(14, CSR_MINSTRET, 0),
            csrrs(15, CSR_MSTATUS, 0), csrrs(16, CSR_MIE, 0)]
    spin = 4 * len(prog)
    prog += [jal(0, 0)]
    await start(core, prog)
    await wait_pc(core, spin)
    await ClockCycles(core.dut.clk_i, 400)
    assert core.x(10) == 0, "mhartid"
    assert core.x(11) == 0x8000000000000100, "misa"
    assert core.x(12) == 21, "mscratch"
    assert core.x(14) - core.x(13) == 2, "minstret does not count retired instructions"
    assert core.x(15) == 0x1800, "mstatus after reset (MPP = 11, MIE = 0)"
    assert core.x(16) == 0, "mie after reset"


async def vectored_irq(core: Core):
    vec = 0x7E00
    prog = ENABLE_MEI + li(2, vec | 1) + [csrrw(0, CSR_MTVEC, 2)]
    prog += [addi(5, 5, 1)] * 30 + [jal(0, 0)]
    isr = {vec + 4 * 11: MRET}
    await start(core, prog, isr)
    await wait_pc(core, 4 * (len(ENABLE_MEI) + 4))
    core.irq(1)
    await wait_pc(core, vec + 4 * 11)
    core.irq(0)
    assert core.csr("mcause") == MCAUSE_INT | 11


async def wfi_wait(core: Core):
    """RV_NoPipeline: WFI stalls until an enabled interrupt is pending."""
    prog = ENABLE_MEI
    a = 4 * len(prog)
    prog += [WFI, addi(9, 0, 1), jal(0, 0)]
    await start(core, prog)
    await wait_pc(core, a)
    await ClockCycles(core.dut.clk_i, 5000)
    assert core.pc() == a and core.x(9) == 0, "core did not wait in WFI"
    core.irq(1)
    await wait_for(core, core.trap, "interrupt trap")
    await wait_for(core, lambda: not core.trap(), "end of trap entry")
    await ClockCycles(core.dut.clk_i, 4)
    core.irq(0)
    assert core.csr("mepc") == a + 4, hex(core.csr("mepc"))
    await wait_pc(core, a + 8)
    await ClockCycles(core.dut.clk_i, 400)
    assert core.x(9) == 1


async def wfi_nop(core: Core):
    """RV_PipelineCacheFwd: WFI is a NOP (allowed by the spec), not illegal."""
    prog = [WFI, addi(9, 0, 1), jal(0, 0)]
    await start(core, prog)
    await wait_pc(core, 8)
    await ClockCycles(core.dut.clk_i, 400)
    assert core.x(9) == 1 and core.csr("mcause") == 0
