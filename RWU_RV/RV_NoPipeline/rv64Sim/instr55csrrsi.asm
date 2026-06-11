# Row 55 (Table B.1): csrrsi - CSR atomic read/set bits with 5-bit immediate
# Write 16 (0x10) to mepc, set bits 9 (0x09) -> mepc = 0x19 = 25; read back.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        addi x1, x0, 16         # base value 0x10
        csrrw  x0,  0x341, x1   # mepc = 0x10
        csrrsi x0,  0x341, 9    # mepc |= 9 -> 0x19 = 25
        csrrs  x10, 0x341, x0   # rd = mepc = 0x19 = 25  (no modify)
        sb   x10, 16(x2)        # print 25 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
