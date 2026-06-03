# Row 23 (Table B.1): sltu - set less than unsigned
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# unsigned: -1 (MAX_UINT) > 0, so 0 <u MAX_UINT = 1
	addi x4, x0, -1       # x4 = MAX_UINT
	sltu x5, x0, x4       # x5 = 1 (0 <u MAX_UINT)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 1 (intermediate)
	# unsigned: MAX_UINT <u 0 = 0 (false)
	sltu x5, x4, x0       # x5 = 0
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0 (intermediate)
	# build 23 = 16 + 7
	addi x4, x0, 1
	sltu x3, x0, x4       # x3 = 1 (0 <u 1)
	slli x3, x3, 4        # x3 = 16
	addi x6, x0, 7
	add  x6, x6, x3       # x6 = 23
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 23 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
