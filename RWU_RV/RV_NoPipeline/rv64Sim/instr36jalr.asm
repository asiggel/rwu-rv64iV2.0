# Row 36 (Table B.1): jalr - jump and link register
# Uses auipc to compute target address, jumps over a trap instruction
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 36       # result to print
	auipc x5, 0           # x5 = PC of auipc
	addi  x5, x5, 16      # x5 = auipc_PC + 16 (target = 4 instr ahead)
	jalr  x1, 0(x5)       # jump to target; link = auipc_PC + 16 + 4 = +20
	addi  x4, x0, 0       # SKIPPED (trap: wrong answer if executed)
	addi x10, x4, 0       # LANDS HERE: x10 = 36
	sb   x10, 16(x2)      # print 36 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
