# Row 41 (Table B.2): slliw - shift left logical immediate word
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# 1 slliw 31 -> 0x80000000 -> sign-extended to 0xFFFFFFFF80000000
	addiw x4, x0, 1
	slliw x5, x4, 31      # x5 = 0xFFFFFFFF80000000
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0 (intermediate, shows word overflow + sign ext)
	# 1 slliw 5 = 32
	slliw x5, x4, 5       # x5 = 32
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 32 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
