# Row 55 (Table B.1): csrrsi - CSR atomic read/set bits with 5-bit immediate
# Write 16 (0x10) to mscratch, set bits 9 (0x09) -> mscratch = 0x19 = 25; read back.
# mscratch has no WARL restriction (mepc[1:0] is always 0).
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        addi x1, x0, 16         # base value 0x10
        csrrw  x0,  0x340, x1   # mscratch = 0x10
        csrrsi x0,  0x340, 9    # mscratch |= 9 -> 0x19 = 25
        csrrs  x10, 0x340, x0   # rd = mscratch = 0x19 = 25  (no modify)
        sb   x10, 16(x2)        # print 25 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
