# hazard_waw_war.asm — WAW and WAR hazard test
#
# In an in-order pipeline, WAW and WAR are transparent (no stall needed):
#
#   WAW (Write-After-Write): both writes execute in order; the second write
#   arrives at WB later, so the final register value is correct.
#
#   WAR (Write-After-Read): the read always sees the OLD value because the
#   reading instruction decodes (reads RF) before the writing instruction
#   reaches WB.  In-order pipelines are immune to WAR by construction.
#
# Expected GPIO byte: 25  (WAW result 20 + WAR result 5)
# Dynamic instruction count (INSTR_COUNT): 10

.global _start

_start: addi x2,  x0, 0x100
        slli x2,  x2, 24         # x2 = GPIO base

        # ── WAW test ──────────────────────────────────────────────────────────
        # Two consecutive writes to x5.  Correct result: x5 = 20 (second write).
        addi x5,  x0,  10        # x5 = 10  (first write to x5)
        addi x5,  x0,  20        # x5 = 20  (WAW: second write; overwrites first)
        addi x11, x5,  0         # x11 = 20 (reads x5 after both writes commit)
        # If WAW handling is broken: x11 = 10 (stale first value)

        # ── WAR test ──────────────────────────────────────────────────────────
        # Read x5 first, then write x5.  x12 must capture the OLD value of x5.
        addi x5,  x0,  5         # x5 = 5   (set up value to be read)
        add  x12, x5,  x0        # x12 = 5  (READ x5 — WAR dependency with next)
        addi x5,  x0,  99        # x5 = 99  (WRITE x5 after read; x12 unchanged)
        # If WAR is broken: x12 might be 99 instead of 5

        # ── combine and output ────────────────────────────────────────────────
        add  x10, x11, x12       # x10 = 20 + 5 = 25
        sb   x10, 16(x2)         # expected: 25
        jal  x0, done
done:   beq  x2, x2, done
