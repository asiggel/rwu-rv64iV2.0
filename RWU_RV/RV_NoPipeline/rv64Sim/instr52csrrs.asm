# Row 52 (Table B.1): csrrs - CSR read and set bits
# Write 0x30 to mtvec, set bit 0x04 -> mtvec = 0x34 = 52; read back into rd.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base = 0x1_0000_0000
        addi x1, x0, 0x30       # initial CSR value
        csrrw x0, 0x305, x1     # mtvec = 0x30  (write, discard old)
        addi x3, x0, 0x04       # bits to set
        csrrs x0, 0x305, x3     # mtvec |= 0x04 -> 0x34
        csrrs x10, 0x305, x0    # rd = mtvec = 0x34 = 52  (no modify: rs1=x0)
        sb   x10, 16(x2)        # print 52 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
