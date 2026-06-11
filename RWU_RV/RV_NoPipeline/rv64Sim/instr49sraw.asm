# Row 49 (Table B.2): sraw - shift right arithmetic word (sign-extends)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# negative: -98 sraw 1 = -49 (0xFF...CF)
	addi x4, x0, -98
	addi x5, x0, 1
	sraw x6, x4, x5        # x6 = -49 (0xFF...CF)
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 0xCF=207 (intermediate)
	# positive: 98 sraw 1 = 49
	addi x4, x0, 98
	sraw x6, x4, x5        # x6 = 49
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 49 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
