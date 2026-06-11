# Row 11 (Table B.1): srli - shift right logical immediate
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# srli does NOT sign-extend: shift -1 right by 63 gives 1
	addi x4, x0, -1       # x4 = 0xFF...FF
	srli x5, x4, 63       # x5 = 1 (logical, no sign extend)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 1 (intermediate)
	# 22 >> 1 = 11
	addi x4, x0, 22
	srli x5, x4, 1        # x5 = 11
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 11 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
