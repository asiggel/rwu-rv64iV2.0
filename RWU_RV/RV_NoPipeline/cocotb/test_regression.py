"""
RV64I Compliance Regression Suite with ISS Scoreboard.

For each of the 57 instruction tests the runner:
  1. Writes the pre-assembled program directly into DUT I-Mem (iram_s array).
  2. Resets the CPU.
  3. Runs the simulation cycle by cycle.  On every *instr_commit_s* rising
     edge it:
       a. compares DUT's PC_instr_r with ISS.pc  → catches wrong branch targets
       b. steps the ISS one instruction
       c. if regWr_final_s=1 and rd≠0, compares the register write value
          → catches wrong ALU results, wrong loaded values, wrong link addresses
  4. On every cs_o rising edge it reads the GPIO data register and checks
     the expected byte value.
  5. Reports PASS only when gpio==expected AND no ISS discrepancies occurred.

Usage (from cocotb/ directory):
    make                          # full regression, all 57 tests
    make MODULE=test_poc          # quick smoke test (single program)
"""

from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from iss import ISS

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MASK64     = (1 << 64) - 1
IMEM_DEPTH = 8192          # words; matches as_pack::imemdepth
TIMEOUT    = 200_000       # fast-clock cycles per program

# ---------------------------------------------------------------------------
# Test table  (program_name, expected_gpio_byte)
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
    • ISS scoreboard  – fires on every instr_commit_s rising edge
    • GPIO monitor    – fires on every cs_o rising edge
    """
    words = _load_words(name)

    # --- Write program into DUT I-Mem (direct array write, bypasses JTAG) ---
    for i in range(IMEM_DEPTH):
        dut.imem.iram_s[i].value = words[i] if i < len(words) else 0

    iss.reset(words)
    await _reset(dut)

    errors:      list[str] = []
    prev_commit: int       = 0
    prev_cs:     int       = 0
    cs_count:    int       = 0

    for _ in range(TIMEOUT):
        await RisingEdge(dut.clk_i)

        # ── ISS scoreboard ──────────────────────────────────────────────
        curr_commit = int(dut.cpu.instr_commit_s.value)
        if prev_commit == 0 and curr_commit == 1:       # rising edge only

            dut_pc = int(dut.cpu.PC_instr_r.value)
            iss_pc = iss.pc

            if dut_pc != iss_pc:
                errors.append(
                    f"PC  ISS=0x{iss_pc:08x}  DUT=0x{dut_pc:08x}"
                )

            iss_rd, iss_val = iss.step()                # advance ISS

            if int(dut.cpu.regWr_final_s.value):
                dut_rd  = (int(dut.cpu.ir_s.value) >> 7) & 0x1F
                dut_val = int(dut.cpu.regfile_data_w_s.value) & MASK64

                # Skip x0 (DUT may physically write it; ISS never does)
                if dut_rd != 0 and iss_rd not in (None, 0):
                    if iss_rd != dut_rd or iss_val != dut_val:
                        errors.append(
                            f"REG DUT_PC=0x{dut_pc:08x}: "
                            f"ISS x{iss_rd}←0x{iss_val:016x}  "
                            f"DUT x{dut_rd}←0x{dut_val:016x}"
                        )
        prev_commit = curr_commit

        # ── GPIO monitor ─────────────────────────────────────────────────
        curr_cs = int(dut.cs_o.value)
        if prev_cs == 0 and curr_cs == 1:               # rising edge only
            cs_count += 1
            gpio = int(dut.asGpio.data_reg_s.value) & 0xFF
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
    Run all 57 RV64I programs with GPIO check + ISS scoreboard.

    Each program is loaded directly into the DUT's I-Mem array and the CPU
    is reset before execution.  The test fails if any program's GPIO output
    does not match the expected value OR if the ISS detects a register-write
    or PC mismatch.
    """
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())   # 100 MHz
    cocotb.start_soon(Clock(dut.tck_i, 100, unit="ns").start())  # 10 MHz JTAG
    dut.tms_i.value = 0
    dut.tdi_i.value = 0

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
