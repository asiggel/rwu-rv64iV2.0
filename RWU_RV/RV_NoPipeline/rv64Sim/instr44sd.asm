# Row 44 (Table B.2): sd - store doubleword
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# store a 64-bit pattern with distinct bytes, read back to verify all bytes
	addi x4, x0, 44       # x4 = 44 = 0x2C
	sd   x4, 8(x0)        # store 64-bit to address 8
	ld   x5, 8(x0)        # load 64-bit back
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 44 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
