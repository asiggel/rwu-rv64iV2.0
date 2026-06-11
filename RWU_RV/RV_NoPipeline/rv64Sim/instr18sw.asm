# Row 18 (Table B.1): sw - store word
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# store 0x80000012 as word; upper 32 bits truncated
	addi x4, x0, -1        # x4 = 0xFF...FF
	slli x4, x4, 32        # x4 = 0xFF...FF_0000_0000 (upper 32 bits set)
	addi x5, x0, 0x12      # x5 = 0x12 = 18
	or   x4, x4, x5        # x4 = 0xFF...FF_0000_0012
	sw   x4, 8(x0)         # stores only lower 32 bits: 0x00000012
	lw   x6, 8(x0)         # x6 = sign_ext(0x00000012) = 18
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 18 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
