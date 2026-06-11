# Row 34 (Table B.1): bltu - branch if less than unsigned
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 34       # correct result
	addi x5, x0, 5
	addi x6, x0, 10
	bltu x5, x6, ltu      # TAKEN (5 <u 10)
	addi x4, x0, 0        # SKIPPED
ltu:	addi x10, x4, 0
	sb   x10, 16(x2)      # print 34 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
