# Row 14 (Table B.1): andi - AND immediate
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 0xFF & 14 = 14
	addi x4, x0, -1       # x4 = 0xFF...FF
	andi x5, x4, 14       # x5 = 14
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 14 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
