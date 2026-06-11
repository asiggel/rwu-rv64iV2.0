# Row 42 (Table B.2): srliw - shift right logical immediate word
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 84 srliw 1 = 42
	addiw x4, x0, 84
	srliw x5, x4, 1       # x5 = 42
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 42 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
