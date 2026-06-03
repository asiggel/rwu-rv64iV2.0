# Row 28 (Table B.1): and
# 0xFF & 28 = 28
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, -1       # x4 = 0xFF...FF
	addi x5, x0, 28       # x5 = 28 = 0x1C
	and  x6, x4, x5       # x6 = 28
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 28 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
