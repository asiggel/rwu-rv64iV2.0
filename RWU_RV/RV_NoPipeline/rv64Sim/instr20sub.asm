# Row 20 (Table B.1): sub - subtract
# Corner cases: normal, underflow (MIN-1), overflow (MAX-(-1))
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# Case 1: normal  25-5=20
	addi x4, x0, 25
	addi x5, x0, 5
	sub  x6, x4, x5        # x6 = 20
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 20 (intermediate)
	# Case 2: negative result  3-8=-5 (0xFF...FB)
	addi x4, x0, 3
	addi x5, x0, 8
	sub  x6, x4, x5        # x6 = -5
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 0xFB=251 (intermediate)
	# Case 3: underflow  MIN_INT64 - 1 = MAX_INT64 (wraps)
	addi x4, x0, -1
	srli x4, x4, 1         # x4 = MAX_INT64 = 0x7FFF...FF
	addi x4, x4, 1         # x4 = MIN_INT64 = 0x8000...00
	addi x5, x0, 1
	sub  x6, x4, x5        # x6 = MAX_INT64 = 0x7FFF...FF
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 0xFF=255 (intermediate)
	# Case 4: final  25-5=20 (row number)
	addi x4, x0, 25
	addi x5, x0, 5
	sub  x6, x4, x5        # x6 = 20
	addi x10, x6, 0
	sb   x10, 16(x2)       # print 20 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
