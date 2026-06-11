# Row 45 (Table B.2): addw - add word (32-bit, sign-extends)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 23 + 22 = 45
	addi x4, x0, 23
	addi x5, x0, 22
	addw x6, x4, x5        # x6 = 45
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 45 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
