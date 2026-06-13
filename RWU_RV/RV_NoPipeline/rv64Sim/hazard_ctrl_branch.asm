# hazard_ctrl_branch.asm — Control-flow hazard: branch taken / not-taken
#
# A 5-stage pipeline resolves branches in EX (stage 3), so two instructions
# that were already fetched must be flushed on every TAKEN branch (2-cycle penalty).
# NOT-TAKEN branches incur no flush.
#
# This test exercises:
#   2× branch TAKEN   (each flushes 2 wrong-path instructions)
#   1× branch NOT-TAKEN (no flush)
#
# Layout: each taken-branch has exactly 2 fill instructions between itself
# and the target label so the flush is directly observable (those instructions
# must NOT execute; a wrong result would show if flushing is broken).
#
# Expected GPIO byte: 22
# Dynamic instruction count (INSTR_COUNT): 14

.global _start

_start: addi x2,  x0, 0x100
        slli x2,  x2, 24         # x2 = GPIO base
        addi x10, x0,  0         # x10 = accumulator = 0
        addi x11, x0,  5         # x11 = 5
        addi x12, x0,  3         # x12 = 3
        addi x13, x0,  5         # x13 = 5  (= x11, so beq x11,x13 is TAKEN)

        # ── Branch 1: TAKEN (x11 == x13) ─────────────────────────────────────
        # Two fill instructions between branch and target must be flushed.
        beq  x11, x13, eq1
        addi x10, x10, 100       # MUST BE FLUSHED (in ID when branch resolves)
        addi x10, x10, 100       # MUST BE FLUSHED (in IF when branch resolves)
eq1:    addi x10, x10, 10        # x10 = 10  (executed only if branch taken)

        # ── Branch 2: NOT TAKEN (x11 != x12) ────────────────────────────────
        # Fall-through is executed; eq2 label is never reached.
        beq  x11, x12, eq2
        addi x10, x10, 5         # EXECUTED (x11=5 ≠ x12=3 → not taken) → x10=15
        jal  x0,  after2
eq2:    addi x10, x10, 100       # NEVER reached
after2:

        # ── Branch 3: TAKEN (x11 == x13) ────────────────────────────────────
        beq  x11, x13, eq3
        addi x10, x10, 100       # MUST BE FLUSHED
        addi x10, x10, 100       # MUST BE FLUSHED
eq3:    addi x10, x10, 7         # x10 = 22

        sb   x10, 16(x2)         # expected: 22
        jal  x0, done
done:   beq  x2, x2, done
