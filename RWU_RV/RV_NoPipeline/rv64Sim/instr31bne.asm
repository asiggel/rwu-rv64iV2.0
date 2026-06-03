# Row 31 (Table B.1): bne - branch if not equal
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 31       # correct result
	addi x5, x0, 5
	addi x6, x0, 99
	bne  x5, x6, neq      # TAKEN (5 != 99)
	addi x4, x0, 0        # SKIPPED
neq:	addi x10, x4, 0
	sb   x10, 16(x2)      # print 31 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
