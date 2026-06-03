# Row 35 (Table B.1): bgeu - branch if greater or equal unsigned
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	addi x4, x0, 35       # correct result
	addi x5, x0, 10
	addi x6, x0, 5
	bgeu x5, x6, gteu     # TAKEN (10 >=u 5)
	addi x4, x0, 0        # SKIPPED
gteu:	addi x10, x4, 0
	sb   x10, 16(x2)      # print 35 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
