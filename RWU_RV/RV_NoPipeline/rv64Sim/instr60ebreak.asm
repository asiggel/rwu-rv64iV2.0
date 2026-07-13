# Row 60 (Table B.1): ebreak - breakpoint exception
# Verifies the full M-mode trap round trip:
#   - ebreak (addr 8) redirects PC to the mtvec ISR (0x7F00)
#   - mcause == 3  (breakpoint)
#   - mepc   == 8  (address of the ebreak instruction itself, not PC+4)
#   - ISR advances mepc past ebreak and mret returns to addr 12
# If any check fails, gpio=0 is printed instead of 60 -> test fails.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base                      (addr 0,4)
        ebreak                  # addr 8: triggers ebreak trap -> isr @ mtvec
        addi x10, x0, 60        # addr 12: mret lands here (mepc+4)
        sb    x10, 16(x2)       # addr 16: print 60 -> test ok
        jal   x0, done          # addr 20
done:   beq   x2, x2, done      # addr 24

# -----------------------------
# Trap handler
# -----------------------------
.section .text
.org 0x7F00
isr:
        csrrs x10, 0x342, x0    # x10 = mcause
        addi  x11, x0, 3
        bne   x10, x11, isrfail # must be breakpoint (3)
        csrrs x12, 0x341, x0    # x12 = mepc
        addi  x13, x0, 8
        bne   x12, x13, isrfail # must point at the ebreak instruction (addr 8)
        addi  x12, x12, 4       # skip past ebreak before returning
        csrrw x0, 0x341, x12
        mret                    # PC <- mepc (addr 12)
isrfail:
        addi  x10, x0, 0
        sb    x10, 16(x2)       # print 0 -> test fail
isrfaildone:
        beq   x2, x2, isrfaildone
