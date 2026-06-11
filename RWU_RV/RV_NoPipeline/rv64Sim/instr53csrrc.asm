# Row 53 (Table B.1): csrrc - CSR read and clear bits
# Write 0x37 to mtvec, clear bit 0x02 -> mtvec = 0x35 = 53; read back into rd.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        addi x1, x0, 0x37       # 0x35 | 0x02
        csrrw x0, 0x305, x1     # mtvec = 0x37
        addi x3, x0, 0x02       # bits to clear
        csrrc x0, 0x305, x3     # mtvec &= ~0x02 -> 0x35
        csrrs x10, 0x305, x0    # rd = mtvec = 0x35 = 53  (no modify)
        sb   x10, 16(x2)        # print 53 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
