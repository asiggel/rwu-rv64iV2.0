# Row 21 (Table B.1): sll - shift left logical
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 1 << 4 = 16
	addi x4, x0, 1
	addi x5, x0, 4
	sll  x6, x4, x5        # x6 = 16
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 16 (intermediate)
	# 21 << 0 = 21
	addi x4, x0, 21
	addi x5, x0, 0
	sll  x6, x4, x5        # x6 = 21
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 21 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
