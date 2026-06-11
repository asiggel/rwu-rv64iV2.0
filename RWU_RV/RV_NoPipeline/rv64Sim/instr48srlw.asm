# Row 48 (Table B.2): srlw - shift right logical word
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 96 srlw 1 = 48
	addi x4, x0, 96
	addi x5, x0, 1
	srlw x6, x4, x5        # x6 = 48
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 48 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
