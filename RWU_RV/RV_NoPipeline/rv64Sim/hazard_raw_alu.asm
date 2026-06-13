# hazard_raw_alu.asm — ALU-to-ALU RAW hazard test
#
# Exercises three forwarding distances:
#   k=1  EX/MEM → EX   (result of instruction N used by N+1)
#   k=2  MEM/WB → EX   (result of instruction N used by N+2)
#   k=3  regfile WBR    (result of instruction N used by N+3, no stall)
#
# All three cases are covered by the forwarding network; no stall cycles expected.
#
# Benchmark kernel (9 instructions after setup):
#   x11 = 1
#   x12 = x11+x11 = 2    ← RAW k=1 on x11
#   x13 = 0  (spacer)
#   x14 = x12+x12 = 4    ← RAW k=2 on x12
#   x15 = 0  (spacer 1)
#   x16 = 0  (spacer 2)
#   x18 = x14+x14 = 8    ← k=3 on x14  (no stall)
#   x10 = x18+x18 = 16   ← RAW k=1 on x18
#   x10 = x10+x10 = 32   ← RAW k=1 on x10
#   x10 = x10+10  = 42   (addi)
#
# Expected GPIO byte: 42  (0x2A)
# Dynamic instruction count (INSTR_COUNT): 14

.global _start

_start: addi x2,  x0, 0x100
        slli x2,  x2, 24         # x2 = 0x0000_0001_0000_0000 (GPIO base)

        # ── RAW k=1 : EX/MEM → EX forwarding ─────────────────────────────────
        addi x11, x0,  1         # x11 = 1
        add  x12, x11, x11       # x12 = 2   (RAW k=1: x11 forwarded from EX/MEM)

        # ── RAW k=2 : MEM/WB → EX forwarding ─────────────────────────────────
        add  x13, x0,  x0        # spacer (x13 = 0; advances x12 to MEM/WB stage)
        add  x14, x12, x12       # x14 = 4   (RAW k=2: x12 forwarded from MEM/WB)

        # ── k=3 : no stall, result already written back ───────────────────────
        add  x15, x0,  x0        # spacer 1
        add  x16, x0,  x0        # spacer 2
        add  x18, x14, x14       # x18 = 8   (k=3: x14 in regfile, no forward needed)

        # ── accumulate final result ────────────────────────────────────────────
        add  x10, x18, x18       # x10 = 16  (RAW k=1 on x18)
        add  x10, x10, x10       # x10 = 32  (RAW k=1 on x10)
        addi x10, x10, 10        # x10 = 42

        sb   x10, 16(x2)         # write result to GPIO data register
        jal  x0, done
done:   beq  x2, x2, done
