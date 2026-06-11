# Row 43 (Table B.2): sraiw - shift right arithmetic immediate word (sign-extends)
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# negative: -86 sraiw 1 = -43 (0xFF...D5)
	addiw x4, x0, -86
	sraiw x5, x4, 1       # x5 = -43 (0xFFFFFFFFFFFFFFD5)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0xD5=213 (intermediate)
	# positive: 86 sraiw 1 = 43
	addiw x4, x0, 86
	sraiw x5, x4, 1       # x5 = 43
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 43 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
