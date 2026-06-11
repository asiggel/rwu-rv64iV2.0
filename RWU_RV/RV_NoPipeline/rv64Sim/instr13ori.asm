# Row 13 (Table B.1): ori - OR immediate
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 8 | 5 = 13  (0x08 | 0x05 = 0x0D)
	addi x4, x0, 8
	ori  x5, x4, 5        # x5 = 13
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 13 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
