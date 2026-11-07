"""
Directed trap / interrupt tests for RV_PipelineCacheFwd (cc_cpupipefwd +
cc_trap_csr). Test bodies are shared with RV_NoPipeline:
RV_NoPipeline/cocotb/trap_tests.py.

    make COCOTB_TEST_MODULES=test_traps
"""

import sys
from pathlib import Path

import cocotb

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "RV_NoPipeline" / "cocotb"))
import trap_tests as T  # noqa: E402


def core(dut):
    return T.Pipeline(dut)


@cocotb.test()
async def irq_straight(dut):     await T.irq_straight(core(dut))
@cocotb.test()
async def irq_jumps(dut):        await T.irq_jumps(core(dut))
@cocotb.test()
async def irq_memory(dut):       await T.irq_memory(core(dut))
@cocotb.test()
async def misaligned_store(dut): await T.misaligned_store(core(dut))
@cocotb.test()
async def misaligned_load(dut):  await T.misaligned_load(core(dut))
@cocotb.test()
async def misaligned_jump(dut):  await T.misaligned_jump(core(dut))
@cocotb.test()
async def illegal_instr(dut):    await T.illegal_instr(core(dut))
@cocotb.test()
async def illegal_csr(dut):      await T.illegal_csr(core(dut))
@cocotb.test()
async def ecall(dut):            await T.ecall(core(dut))
@cocotb.test()
async def ebreak(dut):           await T.ebreak(core(dut))
@cocotb.test()
async def jalr_link(dut):        await T.jalr_link(core(dut))
@cocotb.test()
async def csr_reads(dut):        await T.csr_reads(core(dut))
@cocotb.test()
async def vectored_irq(dut):     await T.vectored_irq(core(dut))
@cocotb.test()
async def wfi_nop(dut):          await T.wfi_nop(core(dut))
