# Row 10 (Table B.1): xori - XOR immediate
.global _start
_start: addi x2, x0, 0x100
	slli x2, x2, 24
	# xori with -1 = bitwise NOT
	addi x4, x0, 42       # x4 = 0x2A
	xori x5, x4, -1       # x5 = ~42 = 0xFF...D5 (complement)
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 0xD5=213 (intermediate)
	# 15 xor 5 = 10
	addi x4, x0, 15       # x4 = 0x0F
	xori x5, x4, 5        # x5 = 0x0F ^ 0x05 = 0x0A = 10
	addi x10, x5, 0
	sb   x10, 16(x2)      # print 10 -> test ok
	jal  x0, done
done:   beq  x2, x2, done
