# Row 37 (Table B.1): jal - jump and link
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 37       # result to print
	jal  x1, target       # jump forward; link = PC + 4
	addi x4, x0, 0        # SKIPPED
target:
	addi x10, x4, 0       # x10 = 37
	sb   x10, 16(x2)      # print 37 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
