# Row 24 (Table B.1): xor
# 27 ^ 3 = 0x1B ^ 0x03 = 0x18 = 24
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# xor with itself = 0
	addi x4, x0, 42
	xor  x5, x4, x4        # x5 = 0
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0 (intermediate)
	# 27 ^ 3 = 24
	addi x4, x0, 27        # 0x1B
	addi x5, x0, 3         # 0x03
	xor  x6, x4, x5        # x6 = 0x18 = 24
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 24 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
