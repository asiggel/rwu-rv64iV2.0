# Row 15 (Table B.1): auipc - add upper immediate to PC
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# two consecutive auipc differ by 4 (instruction size)
	auipc x4, 0           # x4 = PC of this instruction
	auipc x5, 0           # x5 = PC + 4
	sub  x6, x5, x4       # x6 = 4 (shows PC increments by 4)
	addi x10, x6, 0
	sb   x10, 16(x2)      # print 4 (intermediate)
	# output row number 15
	addi x10, x0, 15
	sb   x10, 16(x2)      # print 15 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
