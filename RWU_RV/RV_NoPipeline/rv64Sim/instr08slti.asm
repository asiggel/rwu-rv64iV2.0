# Row 8 (Table B.1): slti - set less than immediate (signed)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# false case: 5 < 3 = 0
	addi x4, x0, 5
	slti x5, x4, 3         # x5 = 0
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0 (intermediate)
	# signed: -1 < 0 = 1
	addi x4, x0, -1
	slti x5, x4, 0         # x5 = 1 (signed: -1 < 0)
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 1 (intermediate)
	# build result 8 = 1 << 3
	slti x3, x0, 1         # x3 = 1 (0 < 1)
	slli x3, x3, 3         # x3 = 8
	addi x10, x3, 0
	sb   x10, 16(x2)       # print 8 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
