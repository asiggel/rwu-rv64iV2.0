"""
Minimal RV64I Instruction Set Simulator (integer base + Zicsr + M-mode).

Only the instructions exercised by the RV_NoPipeline regression suite are
required, but the implementation is complete for RV64I + Zicsr + MRET.

API
---
    iss = ISS()
    iss.reset(imem_words)         # list of 32-bit ints
    rd, val = iss.step()          # returns (None, None) for no register write
    iss.gpio                      # last byte written to the GPIO data register
"""

__all__ = ["ISS"]

MASK64 = (1 << 64) - 1
MASK32 = (1 << 32) - 1

# GPIO data-register address in the memory map
_GPIO_DATA_ADDR = 0x100000010   # 0x100000000 + offset 16


def _sext(val: int, bits: int) -> int:
    """Sign-extend *val* from *bits* wide to 64-bit two's complement."""
    val &= (1 << bits) - 1
    if val >> (bits - 1):
        val -= 1 << bits
    return val & MASK64


def _u64(v: int) -> int: return v & MASK64
def _s64(v: int) -> int:
    v &= MASK64; return v - (1 << 64) if v >> 63 else v
def _u32(v: int) -> int: return v & MASK32
def _s32(v: int) -> int:
    v &= MASK32; return v - (1 << 32) if v >> 31 else v


class ISS:
    """RV64I software reference model."""

    _CSR_RESET: dict[int, int] = {
        0x300: 0x1808,  # mstatus  (MIE=1, MPIE=1)
        0x304: 0x800,   # mie      (MEIE=1)
        0x305: 0x7F00,  # mtvec
        0x341: 0,       # mepc
        0x342: 0,       # mcause
        0x344: 0,       # mip
    }

    # ------------------------------------------------------------------
    def reset(self, imem_words: list[int]) -> None:
        """Load a new program and reset all architectural state."""
        self.x:    list[int]      = [0] * 32
        self.pc:   int            = 0
        self.imem: list[int]      = list(imem_words)
        self.dmem: dict[int, int] = {}          # sparse byte store
        self.csrs: dict[int, int] = dict(self._CSR_RESET)
        self.gpio: int            = 0

    # ------------------------------------------------------------------
    def _rx(self, i: int) -> int:
        return 0 if i == 0 else _u64(self.x[i])

    def _wx(self, i: int, v: int) -> None:
        if i:
            self.x[i] = _u64(v)

    def _mload(self, addr: int, size: int, signed: bool) -> int:
        v = 0
        for i in range(size):
            v |= self.dmem.get(addr + i, 0) << (i * 8)
        return _sext(v, size * 8) if signed else _u64(v)

    def _mstore(self, addr: int, size: int, val: int) -> None:
        if addr == _GPIO_DATA_ADDR:
            self.gpio = val & 0xFF
            return
        for i in range(size):
            self.dmem[addr + i] = (val >> (i * 8)) & 0xFF

    # ------------------------------------------------------------------
    def step(self) -> tuple[int | None, int | None]:
        """
        Execute one instruction at self.pc.

        Returns ``(rd, val)`` where
          * *rd*  is the destination register index (0 = x0 = no effect),
          * *val* is the value written,
          * or ``(None, None)`` when no register file write occurs
            (branches, stores, fence, mret).
        """
        pc  = self.pc
        idx = pc >> 2
        raw = self.imem[idx] if 0 <= idx < len(self.imem) else 0x00000013

        # ------- decode -------
        op   = raw & 0x7F
        rd   = (raw >> 7)  & 0x1F
        f3   = (raw >> 12) & 0x7
        rs1  = (raw >> 15) & 0x1F
        rs2  = (raw >> 20) & 0x1F
        f7b5 = (raw >> 30) & 1          # func7[5] distinguishes SUB/SRA

        # immediates
        ii = _sext(raw >> 20, 12)
        si = _sext(((raw >> 25) << 5) | ((raw >> 7) & 0x1F), 12)
        bi = _sext(
            ((raw >> 31) << 12) | (((raw >> 7)  & 1)    << 11) |
            (((raw >> 25) & 0x3F) << 5) | (((raw >> 8) & 0xF) << 1), 13)
        ui = _sext(raw & 0xFFFFF000, 32)
        ji = _sext(
            ((raw >> 31) << 20)          | (((raw >> 12) & 0xFF) << 12) |
            (((raw >> 20) & 1)  << 11)   | (((raw >> 21) & 0x3FF) << 1), 21)
        zi = (raw >> 15) & 0x1F          # CSR zero-extended 5-bit immediate

        a, b = self._rx(rs1), self._rx(rs2)
        npc = _u64(pc + 4)
        wr:  tuple[int | None, int | None] = (None, None)

        # ------- execute -------

        if op == 0x03:       # LOAD
            addr = _u64(a + ii)
            info = {0:(1,True),1:(2,True),2:(4,True),3:(8,False),
                    4:(1,False),5:(2,False),6:(4,False)}.get(f3)
            if info:
                sz, sgn = info
                val = self._mload(addr, sz, sgn)
                self._wx(rd, val); wr = (rd, val)

        elif op == 0x0F:     # FENCE → NOP on this single-issue CPU
            pass

        elif op == 0x13:     # OP-IMM
            sh = ii & 0x3F
            ops = {0: _u64(a + ii),
                   1: _u64(a << sh),
                   2: int(_s64(a) <  _s64(ii)),
                   3: int(a        < _u64(ii)),
                   4: _u64(a ^ ii),
                   5: _u64(_s64(a) >> sh) if f7b5 else _u64(a >> sh),
                   6: _u64(a | ii),
                   7: _u64(a & ii)}
            val = ops.get(f3, 0)
            self._wx(rd, val); wr = (rd, val)

        elif op == 0x17:     # AUIPC
            val = _u64(pc + ui); self._wx(rd, val); wr = (rd, val)

        elif op == 0x1B:     # OP-IMM-32  (W-suffix I-type)
            sh32 = ii & 0x1F
            a32  = _u32(a)
            if   f3 == 0: val = _sext(_u32(a32 + _u32(ii)), 32)
            elif f3 == 1: val = _sext(_u32(a32 << sh32), 32)
            elif f3 == 5:
                val = (_sext(_u32(_s32(a32) >> sh32), 32) if f7b5
                       else _sext(_u32(a32 >> sh32), 32))
            else: val = 0
            self._wx(rd, val); wr = (rd, val)

        elif op == 0x23:     # STORE
            sz = {0:1, 1:2, 2:4, 3:8}.get(f3, 0)
            if sz:
                self._mstore(_u64(a + si), sz, b)

        elif op == 0x33:     # OP  (R-type, RV32I)
            sh = b & 0x3F
            ops = {0: _u64(a - b) if f7b5 else _u64(a + b),
                   1: _u64(a << sh),
                   2: int(_s64(a) <  _s64(b)),
                   3: int(a        < b),
                   4: _u64(a ^ b),
                   5: _u64(_s64(a) >> sh) if f7b5 else _u64(a >> sh),
                   6: _u64(a | b),
                   7: _u64(a & b)}
            val = ops.get(f3, 0)
            self._wx(rd, val); wr = (rd, val)

        elif op == 0x37:     # LUI
            val = ui; self._wx(rd, val); wr = (rd, val)

        elif op == 0x3B:     # OP-32  (W-suffix R-type, RV64I)
            sh32 = b & 0x1F
            a32, b32 = _u32(a), _u32(b)
            if   f3 == 0: val = _sext(_u32(a32 - b32) if f7b5 else _u32(a32 + b32), 32)
            elif f3 == 1: val = _sext(_u32(a32 << sh32), 32)
            elif f3 == 5:
                val = (_sext(_u32(_s32(a32) >> sh32), 32) if f7b5
                       else _sext(_u32(a32 >> sh32), 32))
            else: val = 0
            self._wx(rd, val); wr = (rd, val)

        elif op == 0x63:     # BRANCH
            taken = {0: a == b,       1: a != b,
                     4: _s64(a) < _s64(b),  5: _s64(a) >= _s64(b),
                     6: a < b,        7: a >= b}.get(f3, False)
            if taken:
                npc = _u64(pc + bi)

        elif op == 0x67:     # JALR
            npc = _u64((a + ii) & ~1)
            val = _u64(pc + 4); self._wx(rd, val); wr = (rd, val)

        elif op == 0x6F:     # JAL
            npc = _u64(pc + ji)
            val = _u64(pc + 4); self._wx(rd, val); wr = (rd, val)

        elif op == 0x73:     # SYSTEM  (CSR / MRET)
            csr = (raw >> 20) & 0xFFF
            if f3 == 0:
                if (raw >> 20) == 0x302:   # MRET
                    npc = _u64(self.csrs.get(0x341, 0))  # PC = mepc
                    ms  = self.csrs.get(0x300, 0)
                    mpie = (ms >> 7) & 1
                    # MIE ← MPIE, MPIE ← 1
                    self.csrs[0x300] = (ms & ~0x88) | (mpie << 3) | (1 << 7)
            elif f3 in (1, 2, 3, 5, 6, 7):   # CSR read-modify-write
                old = self.csrs.get(csr, 0)
                src = a if f3 < 5 else zi      # register vs. immediate variant
                new = {1: src, 2: old | src, 3: old & ~src,
                       5: src, 6: old | src, 7: old & ~src}[f3]
                self.csrs[csr] = _u64(new)
                self._wx(rd, old); wr = (rd, _u64(old))

        self.pc = npc
        return wr
