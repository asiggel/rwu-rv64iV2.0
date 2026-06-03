# Row 16 (Table B.1): sb - store byte
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# store 0xAB at address 8; only lowest byte is stored
	addi x4, x0, 0x7AB    # x4 = 0x7AB (upper bits should be truncated)
	sb   x4, 8(x0)        # store only 0xAB to address 8
	lb   x5, 8(x0)        # load back: x5 = sign_ext(0xAB) = 0xFF...AB
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0xAB=171 (intermediate, shows truncation)
	# store 16 and read it back
	addi x4, x0, 16
	sb   x4, 8(x0)
	lbu  x5, 8(x0)        # x5 = 16
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 16 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
