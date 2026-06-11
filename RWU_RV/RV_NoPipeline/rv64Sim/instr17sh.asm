# Row 17 (Table B.1): sh - store halfword
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# store 0x1234 as halfword; only lower 16 bits stored
	lui  x4, 0xABCDE      # x4 = 0xABCDE000 (upper bits to be truncated)
	addi x4, x4, 0x117    # x4 = 0xABCDE117 (0x0117 = 279 in lower half... hmm)
	sh   x4, 8(x0)        # stores only 0x0117 to address 8
	lhu  x5, 8(x0)        # x5 = 0x0117 = 279 (zero extended, upper bits gone)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0x17=23 (intermediate, shows truncation LSB)
	# store 17 as halfword and read back
	addi x4, x0, 17
	sh   x4, 8(x0)
	lhu  x5, 8(x0)        # x5 = 17
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 17 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
