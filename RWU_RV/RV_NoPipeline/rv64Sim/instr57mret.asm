# Row 57 (Table B.1): mret - machine-mode return from trap
# Uses auipc to compute jump target, stores it in mepc, then mret redirects PC.
# If mret fails (falls through), gpio=0 is printed instead of 57 -> test fails.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        auipc x1, 0             # x1 = PC of this instruction (addr 8)
        addi  x1, x1, 28        # x1 = addr 36 (7 instructions ahead = target)
        csrrw x0, 0x341, x1     # mepc = target
        mret                    # PC <- mepc  (jumps to target)
        addi  x10, x0, 0        # SKIPPED: wrong result if executed
        sb    x10, 16(x2)       # SKIPPED: would print 0
        jal   x0, done          # SKIPPED
target: addi  x10, x0, 57       # x10 = 57  (mret lands here)
        sb    x10, 16(x2)       # print 57 -> test ok
        jal   x0, done
done:   beq   x2, x2, done
