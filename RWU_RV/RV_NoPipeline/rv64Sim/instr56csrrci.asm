# Row 56 (Table B.1): csrrci - CSR atomic read/clear bits with 5-bit immediate
# Write 29 (0x1D) to mepc, clear bits 9 (0x09) -> mepc = 0x1D & ~0x09 = 0x14 = 20; read back.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        addi x1, x0, 29         # 0x1D = 0x14 | 0x09
        csrrw  x0,  0x341, x1   # mepc = 0x1D
        csrrci x0,  0x341, 9    # mepc &= ~9 -> 0x14 = 20
        csrrs  x10, 0x341, x0   # rd = mepc = 0x14 = 20  (no modify)
        sb   x10, 16(x2)        # print 20 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
