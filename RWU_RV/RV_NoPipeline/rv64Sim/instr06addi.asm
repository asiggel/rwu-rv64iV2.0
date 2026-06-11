# RISC-V Assembly              Description
# Row 6 (Table B.1): addi - add immediate
# Corner cases: normal pos/neg, overflow pos (MAX+1), overflow neg (MIN-1)
.global _start

_start: addi x2, x0, 0x100     # GPIO base address
	slli x2, x2, 24        # x2 = 0x00000001_00000000
	# Case 1: normal positive  4+2=6
	addi x4, x0, 4
	addi x5, x4, 2         # x5 = 6
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 6 (intermediate)
	# Case 2: normal negative  (-3)+(-18)=-21
	addi x4, x0, -3
	addi x5, x4, -18       # x5 = -21 (0xFF...EB)
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0xEB=235 (intermediate)
	# Case 3: overflow positive  MAX_INT64 + 1 = MIN_INT64
	addi x4, x0, -1        # x4 = 0xFF...FF
	srli x4, x4, 1         # x4 = 0x7FFF...FF (MAX_INT64)
	addi x5, x4, 1         # x5 = 0x8000...00 (MIN_INT64, wraps)
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0x00=0 (intermediate)
	# Case 4: overflow negative  MIN_INT64 + (-1) = MAX_INT64
	addi x5, x5, -1        # x5 = 0x7FFF...FF (MAX_INT64, wraps)
	addi x10, x5, 0
	sb   x10, 16(x2)       # print 0xFF=255 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
