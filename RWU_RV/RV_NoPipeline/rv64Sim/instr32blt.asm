# Row 32 (Table B.1): blt - branch if less than (signed)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 32       # correct result
	addi x5, x0, 5
	addi x6, x0, 10
	blt  x5, x6, less     # TAKEN (5 < 10 signed)
	addi x4, x0, 0        # SKIPPED
less:	addi x10, x4, 0
	sb   x10, 16(x2)      # print 32 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
