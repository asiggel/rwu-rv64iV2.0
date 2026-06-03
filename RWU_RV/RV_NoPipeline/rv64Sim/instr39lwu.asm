# Row 39 (Table B.2): lwu - load word unsigned (zero-extends to 64 bit)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# Store a word with bit 31 set; lw sign-extends, lwu zero-extends
	addi x4, x0, -1       # x4 = 0xFF...FF
	slli x4, x4, 32       # x4 = 0xFF...FF_0000_0000
	xori x4, x4, -1       # x4 = 0x0000_0000_FFFF_FFFF
	slli x4, x4, 1        # x4 = 0x0000_0001_FFFF_FFFE
	srli x4, x4, 1        # x4 = 0x0000_0000_FFFF_FFFF = 0x00000000FFFFFFFF
	sw   x4, 8(x0)        # store lower 32 bits: 0xFFFFFFFF
	lw   x5, 8(x0)        # sign-extended: 0xFFFFFFFFFFFFFFFF
	lwu  x6, 8(x0)        # zero-extended: 0x00000000FFFFFFFF
	sub  x7, x6, x5       # x7 = 0x00000000FFFFFFFF - 0xFFFFFFFFFFFFFFFF = 1
	addi x10, x7, 0
	sb   x10, 16(x2)      # print 1 (intermediate, shows lw vs lwu differ)
	# store 39 and load as unsigned word
	addi x4, x0, 39
	sw   x4, 8(x0)
	lwu  x5, 8(x0)        # x5 = 39 (zero extended)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 39 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
