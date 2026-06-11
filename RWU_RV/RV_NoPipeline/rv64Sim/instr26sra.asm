# Row 26 (Table B.1): sra - shift right arithmetic (sign-extends)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# sra sign-extends: -52 >> 1 = -26 (0xFF...E6)
	addi x4, x0, -52
	addi x5, x0, 1
	sra  x6, x4, x5       # x6 = -26 (0xFF...E6)
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 0xE6=230 (intermediate)
	# positive: 52 >> 1 = 26
	addi x4, x0, 52
	sra  x6, x4, x5       # x6 = 26
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 26 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
