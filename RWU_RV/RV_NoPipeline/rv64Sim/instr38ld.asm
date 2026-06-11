# Row 38 (Table B.2): ld - load doubleword (64-bit)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# store 64-bit value 0xABCDEF00_00000026 then load it back
	addi x4, x0, 38       # lower 38 in LSB
	sd   x4, 8(x0)        # store 64-bit
	ld   x5, 8(x0)        # load 64-bit
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 38 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
