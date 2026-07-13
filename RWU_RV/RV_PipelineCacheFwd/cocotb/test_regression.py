"""
RV64I Compliance Regression Suite with ISS Scoreboard — RV_PipelineCacheFwd.

Adapted from RV_NoPipeline/cocotb/test_regression.py for the 5-stage pipeline
(cc_cpupipefwd). Key differences from the RV_NoPipeline harness:

  - Program loading: this design has no directly-pokeable instruction RAM —
    instructions only reach the CPU through the I-cache's AXI4 fill path from
    a simulated QSPI flash (see ../tb/tb_rv64i_instr.sv's flash_transaction
    task). tb_flash_wrap.sv carries the same flash model so cocotb can still
    load a program with a direct array poke (flash_mem_s), bypassing JTAG
    exactly like RV_NoPipeline bypasses it — but NOT bypassing the cache/AXI4
    path itself, which stays fully exercised.
  - Retirement point: wb_commit_s (WB stage) instead of instr_commit_s;
    PC_instr_r -> mem_wb_pc_r; regWr_final_s -> wb_regWr_final_s;
    regfile_data_w_s -> wb_result_s; rd comes from mem_wb_instr_r[11:7].

For each instruction test the runner:
  1. Writes the pre-assembled program into flash_mem_s (direct array poke).
  2. Resets the CPU.
  3. Runs the simulation cycle by cycle. On every *wb_commit_s* rising edge:
       a. compares DUT's mem_wb_pc_r with ISS.pc  -> catches wrong branch
          targets AND wrong pipeline-flush timing (the RV_NoPipeline
          stale-prefetch bug class this suite exists to catch).
       b. steps the ISS one instruction.
       c. if wb_regWr_final_s=1 and rd != 0, compares the register write
          value -> catches wrong ALU/load/CSR/trap results.
  4. On every cs_o rising edge it reads the GPIO data register and checks
     the expected byte value.
  5. Reports PASS only when gpio==expected AND no ISS discrepancies occurred.

Usage (from cocotb/ directory):
    make                          # full regression
    make COCOTB_TEST_MODULES=test_poc
"""

from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from iss import ISS

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MASK64      = (1 << 64) - 1
FLASH_WORDS = 16384        # words; matches tb_flash_wrap.sv FLASH_WORDS
TIMEOUT     = 3_000_000    # fast-clock cycles per program (cache-fill/QSPI is
                            # far slower than RV_NoPipeline's direct SRAM read)

# ---------------------------------------------------------------------------
# Test table  (program_name, expected_gpio_byte) — identical to RV_NoPipeline,
# same .asm sources (RV_NoPipeline/rv64Sim), same expected results.
# ---------------------------------------------------------------------------
PROGRAMS: list[tuple[str, int]] = [
    # ---- Table B.1 loads ----
    ("instr01loadbyte",  128),
    ("instr02loadhalf",    7),
    ("instr03loadword",    5),
    ("instr04loadbyteu", 128),
    ("instr05loadhalfu",   7),
    # ---- I-type ALU ----
    ("instr06addi",      255),
    ("instr07slli",        1),
    ("instr08slti",        8),
    ("instr09sltiu",       9),
    ("instr10xori",       10),
    ("instr11srli",       11),
    ("instr12srai",       12),
    ("instr13ori",        13),
    ("instr14andi",       14),
    # ---- PC-relative ----
    ("instr15auipc",      15),
    # ---- Stores ----
    ("instr16sb",         16),
    ("instr17sh",         17),
    ("instr18sw",         18),
    # ---- R-type ALU ----
    ("instr19add",       254),
    ("instr20sub",        20),
    ("instr21sll",        21),
    ("instr22slt",        22),
    ("instr23sltu",       23),
    ("instr24xor",        24),
    ("instr25srl",        25),
    ("instr26sra",        26),
    ("instr27or",         27),
    ("instr28and",        28),
    # ---- U-type ----
    ("instr29lui",        29),
    # ---- Branches ----
    ("instr30beq",        30),
    ("instr31bne",        31),
    ("instr32blt",        32),
    ("instr33bge",        33),
    ("instr34bltu",       34),
    ("instr35bgeu",       35),
    # ---- Jumps ----
    ("instr36jalr",       36),
    ("instr37jal",        37),
    # ---- RV64I extra loads ----
    ("instr38ld",         38),
    ("instr39lwu",        39),
    # ---- RV64I W-suffix I-type ----
    ("instr40addiw",      40),
    ("instr41slliw",      32),
    ("instr42srliw",      42),
    ("instr43sraiw",      43),
    # ---- RV64I double store ----
    ("instr44sd",         44),
    # ---- RV64I W-suffix R-type ----
    ("instr45addw",       45),
    ("instr46subw",       46),
    ("instr47sllw",       47),
    ("instr48srlw",       48),
    ("instr49sraw",       49),
    # ---- System / Zicsr ----
    ("instr51csrrw",      29),
    ("instr52csrrs",      52),
    ("instr53csrrc",      53),
    ("instr54csrrwi",     22),
    ("instr55csrrsi",     25),
    ("instr56csrrci",     20),
    ("instr57mret",       57),
    # ---- Fence ----
    ("instr58fence",      58),
    # ---- Traps: ECALL / EBREAK ----
    ("instr59ecall",      59),
    ("instr60ebreak",     60),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _load_words(name: str) -> list[int]:
    return [int(ln.strip(), 16)
            for ln in Path(f"programs/{name}.mem").read_text().splitlines()
            if ln.strip()]


async def _reset(dut) -> None:
    dut.rst_i.value  = 1
    dut.trst_i.value = 1
    for _ in range(20):
        await RisingEdge(dut.clk_i)
    dut.rst_i.value  = 0
    dut.trst_i.value = 0


async def _run_program(dut, name: str, expected: int,
                       iss: ISS) -> tuple[bool, list[str]]:
    """
    Load *name*, run it, and return (passed, error_list).

    Two independent checks run concurrently in the same clock loop:
    • ISS scoreboard  – fires on every wb_commit_s rising edge
    • GPIO monitor    – fires on every cs_o rising edge
    """
    words = _load_words(name)

    # --- Write program into the simulated flash (direct array write,
    #     bypasses JTAG but NOT the I-cache/AXI4/QSPI-model path) ---
    for i in range(FLASH_WORDS):
        dut.flash_mem_s[i].value = words[i] if i < len(words) else 0

    iss.reset(words)
    await _reset(dut)

    errors:      list[str] = []
    prev_cs:     int       = 0
    cs_count:    int       = 0
    prev_cpu_clk: int      = 0

    for _ in range(TIMEOUT):
        await RisingEdge(dut.clk_i)

        # ── ISS scoreboard ──────────────────────────────────────────────
        # wb_commit_s lives in the CPU's own (divided) clock domain and is a
        # *level*, not a pulse: wb_committed_r only resets to 0 while
        # !global_stall_s, so during unstalled back-to-back retirement
        # wb_commit_s can legitimately stay 1 across two *adjacent CPU
        # cycles*, each representing a *different* instruction (unlike
        # RV_NoPipeline's instr_commit_s, which is a clean one-cycle pulse
        # on the CPU's own clock with no divider in between).
        # Sampling here on every *fast* dut.clk_i edge means a single CPU
        # cycle is oversampled ~80x, so neither edge-detecting wb_commit_s
        # (misses back-to-back commits: 1->1 across the CPU-clock boundary
        # looks like "no change" to the fast-clock sampler) nor level-
        # checking it (re-triggers on every oversampled fast cycle) is
        # correct on its own. Detecting the CPU's own clock edge first,
        # and only then level-checking wb_commit_s, samples exactly once
        # per real CPU cycle regardless of which pattern wb_commit_s takes.
        curr_cpu_clk = int(dut.DUT.cpu.clk_i.value)
        cpu_clk_rose = (prev_cpu_clk == 0 and curr_cpu_clk == 1)
        prev_cpu_clk = curr_cpu_clk

        if cpu_clk_rose and int(dut.DUT.cpu.wb_commit_s.value) == 1:

            dut_pc = int(dut.DUT.cpu.mem_wb_pc_r.value)
            iss_pc = iss.pc

            if dut_pc != iss_pc:
                errors.append(
                    f"PC  ISS=0x{iss_pc:08x}  DUT=0x{dut_pc:08x}"
                )

            iss_rd, iss_val = iss.step()                # advance ISS

            if int(dut.DUT.cpu.wb_regWr_final_s.value):
                dut_rd  = (int(dut.DUT.cpu.mem_wb_instr_r.value) >> 7) & 0x1F
                dut_val = int(dut.DUT.cpu.wb_result_s.value) & MASK64

                # Skip x0 (DUT may physically write it; ISS never does)
                if dut_rd != 0 and iss_rd not in (None, 0):
                    if iss_rd != dut_rd or iss_val != dut_val:
                        errors.append(
                            f"REG DUT_PC=0x{dut_pc:08x}: "
                            f"ISS x{iss_rd}<-0x{iss_val:016x}  "
                            f"DUT x{dut_rd}<-0x{dut_val:016x}"
                        )

        # ── GPIO monitor ─────────────────────────────────────────────────
        curr_cs = int(dut.cs_o.value)
        if prev_cs == 0 and curr_cs == 1:               # rising edge only
            cs_count += 1
            gpio = int(dut.DUT.asGpio.data_reg_s.value) & 0xFF
            if gpio == expected:
                return (len(errors) == 0), errors
            if cs_count >= 20:
                errors.append(
                    f"gpio=0x{gpio:02x} never matched "
                    f"expected=0x{expected:02x} after 20 CS pulses"
                )
                return False, errors
        prev_cs = curr_cs

    errors.append(f"TIMEOUT after {TIMEOUT} fast-clock cycles")
    return False, errors


# ---------------------------------------------------------------------------
# cocotb test entry point
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_all_programs(dut):
    """
    Run all RV64I programs with GPIO check + ISS scoreboard.

    Each program is loaded directly into the simulated flash array and the
    CPU is reset before execution. The test fails if any program's GPIO
    output does not match the expected value OR if the ISS detects a
    register-write or PC mismatch (which would also catch a pipeline-flush
    timing bug analogous to the one found and fixed in RV_NoPipeline).
    """
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())   # 100 MHz
    cocotb.start_soon(Clock(dut.tck_i, 100, unit="ns").start())  # 10 MHz JTAG
    dut.tms_i.value = 0
    dut.tdi_i.value = 0
    dut.uart0_rx_i.value = 1

    iss      = ISS()
    failures: list[str] = []

    for name, expected in PROGRAMS:
        passed, errs = await _run_program(dut, name, expected, iss)
        status = "PASS" if passed else "FAIL"
        dut._log.info(f"[{status}] {name:20s}  expected=0x{expected:02x}")
        if not passed:
            for e in errs:
                dut._log.error(f"         {e}")
            failures.append(name)

    summary = f"{len(PROGRAMS) - len(failures)}/{len(PROGRAMS)} passed"
    assert not failures, f"Regression FAILED ({summary}): {failures}"
    dut._log.info(f"Regression PASSED  ({summary})")
