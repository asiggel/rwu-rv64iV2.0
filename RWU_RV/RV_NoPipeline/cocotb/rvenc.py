"""
Tiny RV64I instruction encoder for directed cocotb tests (no assembler needed).
Used by trap_tests.py (RV_NoPipeline and RV_PipelineCacheFwd).
"""

NOP    = 0x00000013
ECALL  = 0x00000073
EBREAK = 0x00100073
MRET   = 0x30200073
WFI    = 0x10500073

CSR_MSTATUS  = 0x300
CSR_MISA     = 0x301
CSR_MIE      = 0x304
CSR_MTVEC    = 0x305
CSR_MSCRATCH = 0x340
CSR_MEPC     = 0x341
CSR_MCAUSE   = 0x342
CSR_MTVAL    = 0x343
CSR_MIP      = 0x344
CSR_MINSTRET = 0xB02
CSR_MHARTID  = 0xF14


def _i(op, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(f3, rs1, rs2, imm):
    i = imm & 0xFFF
    return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1F) << 7) | 0x23


def addi(rd, rs1, imm):  return _i(0x13, rd, 0, rs1, imm)
def ld(rd, rs1, imm):    return _i(0x03, rd, 3, rs1, imm)
def lw(rd, rs1, imm):    return _i(0x03, rd, 2, rs1, imm)
def jalr(rd, rs1, imm):  return _i(0x67, rd, 0, rs1, imm)
def sd(rs2, rs1, imm):   return _s(3, rs1, rs2, imm)
def sw(rs2, rs1, imm):   return _s(2, rs1, rs2, imm)
def lui(rd, imm20):      return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def jal(rd, off):
    o = off & 0x1FFFFF
    return ((((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20)
            | (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F)


def beq(rs1, rs2, off):
    o = off & 0x1FFF
    return ((((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15)
            | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63)


def csrrw(rd, csr, rs1):   return _i(0x73, rd, 1, rs1, csr)
def csrrs(rd, csr, rs1):   return _i(0x73, rd, 2, rs1, csr)
def csrrc(rd, csr, rs1):   return _i(0x73, rd, 3, rs1, csr)
def csrrwi(rd, csr, uimm): return _i(0x73, rd, 5, uimm, csr)
def csrrsi(rd, csr, uimm): return _i(0x73, rd, 6, uimm, csr)


def li(rd, val):
    """lui + addi for a signed 32-bit constant."""
    lo = val & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((val - lo) >> 12) & 0xFFFFF
    return [lui(rd, hi), addi(rd, rd, lo)]
