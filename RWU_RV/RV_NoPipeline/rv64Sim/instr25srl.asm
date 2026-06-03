# Row 25 (Table B.1): srl - shift right logical
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# srl does NOT sign-extend: -2 >> 1 = large positive
	addi x4, x0, -2       # x4 = 0xFF...FE
	addi x5, x0, 1
	srl  x6, x4, x5       # x6 = 0x7FFF...FF (no sign ext)
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 0xFF=255 (intermediate, MSB cleared)
	# 50 >> 1 = 25
	addi x4, x0, 50
	addi x5, x0, 1
	srl  x6, x4, x5       # x6 = 25
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 25 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
