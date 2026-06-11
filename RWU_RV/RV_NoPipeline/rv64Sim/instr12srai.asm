# Row 12 (Table B.1): srai - shift right arithmetic immediate
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# srai sign-extends: -24 >> 1 = -12 (0xFF...F4)
	addi x4, x0, -24
	srai x5, x4, 1        # x5 = -12 (0xFFF...FF4)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0xF4=244 (intermediate)
	# positive: 24 >> 1 = 12
	addi x4, x0, 24
	srai x5, x4, 1        # x5 = 12
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 12 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
