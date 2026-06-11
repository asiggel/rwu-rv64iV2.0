# Row 22 (Table B.1): slt - set less than (signed)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# signed: -1 < 0 = 1
	addi x4, x0, -1
	slt  x5, x4, x0        # x5 = 1 (signed -1 < 0)
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 1 (intermediate)
	# signed: 0 < -1 = 0 (false)
	slt  x5, x0, x4        # x5 = 0
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0 (intermediate)
	# build 22 = 16 + 6
	addi x4, x0, 1
	slt  x3, x0, x4        # x3 = 1 (0 < 1)
	slli x3, x3, 4         # x3 = 16
	addi x6, x0, 6
	add  x6, x6, x3        # x6 = 22
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 22 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
