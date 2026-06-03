# Row 46 (Table B.2): subw - subtract word (32-bit, sign-extends)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 50 - 4 = 46
	addi x4, x0, 50
	addi x5, x0, 4
	subw x6, x4, x5        # x6 = 46
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 46 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
