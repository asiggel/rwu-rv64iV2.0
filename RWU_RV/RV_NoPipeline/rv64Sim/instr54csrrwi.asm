# Row 54 (Table B.1): csrrwi - CSR atomic read/write with 5-bit immediate
# zimm field is 5 bits (0-31); write imm=22 to mtvec, read back into rd.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        csrrwi x0,  0x305, 22   # mtvec = 22  (write imm, discard old)
        csrrs  x10, 0x305, x0   # rd = mtvec = 22
        sb   x10, 16(x2)        # print 22 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
