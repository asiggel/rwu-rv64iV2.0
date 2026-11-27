# RISC-V Assembly              Description
# Boundary-scan test (tb_rv64i_instr99bscan.sv): drive a fixed GPIO state, so
# that the boundary-scan output and control cells capture known core values.
.global _start

_start: addi x2, x0, 0x100     # GPIO base address
	slli x2, x2, 24        # x2 = 0x00000001_00000000
	addi x4, x0, 0xF0      # GPIO 7..4 input, 3..0 output
	sd   x4, 8(x2)         # direction register
	addi x5, x0, 0x05      # GPIO 3..0 = 0101
	sd   x5, 16(x2)        # data register
	jal  x0, done
done:   beq  x2, x2, done
