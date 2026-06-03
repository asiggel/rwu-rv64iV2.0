# Row 27 (Table B.1): or
# 24 | 3 = 0x18 | 0x03 = 0x1B = 27
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 24       # 0x18
	addi x5, x0, 3        # 0x03
	or   x6, x4, x5       # x6 = 0x1B = 27
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 27 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
