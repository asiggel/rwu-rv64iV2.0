# hazard_raw_load.asm — Load-use RAW hazard test
#
# Each load-use pair forces a 1-cycle stall because the loaded value is not
# available until the MEM stage, which is too late for the next instruction's EX.
# The pipeline inserts a bubble, then forwards via MEM/WB → EX.
#
# Three load-use pairs store values 1, 2, 4 into SRAM, load them back,
# and immediately consume the result.  Sum = 7.
#
# Expected GPIO byte: 7
# Dynamic instruction count (INSTR_COUNT): 15

.global _start

_start: addi x2,  x0, 0x100
        slli x2,  x2, 24         # x2 = 0x0000_0001_0000_0000 (GPIO base)

        # ── Load-use pair 1 ───────────────────────────────────────────────────
        addi x11, x0,  1
        sb   x11, 8(x0)          # SRAM[8] = 1
        lb   x12, 8(x0)          # load byte → x12 = 1
        add  x13, x12, x0        # RAW load-use on x12 → 1-cycle stall; x13 = 1

        # ── Load-use pair 2 ───────────────────────────────────────────────────
        addi x11, x0,  2
        sb   x11, 9(x0)          # SRAM[9] = 2
        lb   x14, 9(x0)          # load byte → x14 = 2
        add  x15, x14, x0        # RAW load-use on x14 → 1-cycle stall; x15 = 2

        # ── Load-use pair 3 ───────────────────────────────────────────────────
        addi x11, x0,  4
        sb   x11, 10(x0)         # SRAM[10] = 4
        lb   x16, 10(x0)         # load byte → x16 = 4
        add  x17, x16, x0        # RAW load-use on x16 → 1-cycle stall; x17 = 4

        # ── combine results ───────────────────────────────────────────────────
        add  x10, x13, x15       # x10 = 1+2 = 3
        add  x10, x10, x17       # x10 = 3+4 = 7

        sb   x10, 16(x2)         # write result to GPIO data register
        jal  x0, done
done:   beq  x2, x2, done
