# Row 30 (Table B.1): beq - branch if equal
# Tests taken branch: beq jumps over an instruction that would corrupt x4
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 30       # correct result
	addi x5, x0, 7
	addi x6, x0, 7
	beq  x5, x6, eq       # TAKEN (7==7): skip the zeroing instruction
	addi x4, x0, 0        # SKIPPED — would give wrong answer if executed
eq:	addi x10, x4, 0       # x10 = 30 if branch was taken
	sb   x10, 16(x2)      # print 30 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
