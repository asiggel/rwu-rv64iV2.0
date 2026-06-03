# Row 47 (Table B.2): sllw - shift left logical word
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 1 sllw 4 = 16 (intermediate)
	addi x4, x0, 1
	addi x5, x0, 4
	sllw x6, x4, x5        # x6 = 16
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 16 (intermediate)
	# 47 sllw 0 = 47
	addi x4, x0, 47
	addi x5, x0, 0
	sllw x6, x4, x5        # x6 = 47 (shift by 0)
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 47 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
