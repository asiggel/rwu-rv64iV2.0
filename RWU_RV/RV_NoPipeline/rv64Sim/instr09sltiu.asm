# Row 9 (Table B.1): sltiu - set less than immediate (unsigned)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# unsigned: -1 (=MAX_UINT) <u 1 = 0
	addi x4, x0, -1
	sltiu x5, x4, 1        # x5 = 0 (MAX_UINT not < 1 unsigned)
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0 (intermediate)
	# signed -1 < 1 is true but unsigned it is false — show sltiu differs from slti
	slti  x6, x4, 1        # x6 = 1 (signed: -1 < 1)
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 1 (intermediate, shows difference)
	# build result 9
	sltiu x3, x0, 1        # x3 = 1 (0 <u 1)
	slli  x3, x3, 3        # x3 = 8
	addi  x3, x3, 1        # x3 = 9
	addi x10, x3, 0
	sb   x10, 16(x2)       # print 9 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
