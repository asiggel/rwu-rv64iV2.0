# Row 40 (Table B.2): addiw - add immediate word (32-bit, sign-extends to 64)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# overflow at 32-bit boundary: 0x7FFFFFFF + 1 wraps to 0xFFFFFFFF80000000
	addi x4, x0, -1
	srli x4, x4, 33       # x4 = 0x000000007FFFFFFF (MAX_INT32)
	addiw x5, x4, 1       # x5 = 0xFFFFFFFF80000000 (wraps at 32 bits)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0=LSB of 0x80000000 (intermediate)
	# 40 via addiw
	addiw x5, x0, 40      # x5 = 40 (sign-extended from 32-bit 40)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 40 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
