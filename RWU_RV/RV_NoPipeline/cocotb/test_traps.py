"""
Directed trap / interrupt tests for RV_NoPipeline (as_cpux + cc_trap_csr).
Test bodies: trap_tests.py.

    make COCOTB_TEST_MODULES=test_traps
"""

import cocotb

import trap_tests as T


def core(dut):
    return T.NoPipeline(dut)


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
async def wfi_wait(dut):         await T.wfi_wait(core(dut))
