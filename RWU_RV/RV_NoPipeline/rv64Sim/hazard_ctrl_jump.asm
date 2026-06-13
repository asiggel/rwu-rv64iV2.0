# hazard_ctrl_jump.asm — Control-flow hazard: JAL and JALR
#
# JAL and JALR both redirect the PC and cause a 2-cycle flush (same pipeline
# penalty as a taken branch).
#
# Tests:
#   1. JAL forward  — jumps to target1, two fill instructions flushed
#   2. JAL + backward loop — body runs exactly once (BEQ taken on exit)
#   3. JAL call + JALR return — subroutine call via JAL, return via JALR
#
# Execution trace:
#   x10 = 0
#   JAL → target1  : x10 += 10  → x10 = 10
#   loop body once : x10 +=  5  → x10 = 15
#   func3 call     : x10 += 22  → x10 = 37
#
# Expected GPIO byte: 37
# Dynamic instruction count (INSTR_COUNT): 16

.global _start

_start: addi x2,  x0, 0x100
        slli x2,  x2, 24         # x2 = GPIO base
        addi x10, x0,  0         # accumulator = 0

        # ── JAL forward: two fill instructions must be flushed ────────────────
        jal  x1,  target1
        addi x10, x10, 100       # MUST BE FLUSHED (in ID)
        addi x10, x10, 100       # MUST BE FLUSHED (in IF)
target1:
        addi x10, x10, 10        # x10 = 10

        # ── JAL backward loop: body executes exactly once ─────────────────────
        # Structure: jump to check first, run body once, exit when x11 reaches 0.
        addi x11, x0,  1
        jal  x0,  check          # skip body on first entry
body:   addi x10, x10, 5         # x10 += 5  (runs once)
check:  beq  x11, x0,  after_loop  # exit when x11 == 0
        addi x11, x11, -1        # x11-- (from 1 to 0)
        jal  x0,  body           # loop back
after_loop:
        # x10 = 15

        # ── JAL call + JALR return: subroutine at func3 ──────────────────────
        jal  x1,  func3          # call func3; x1 = return address
        jal  x0,  after3         # executed after JALR returns; skipped by JAL itself
func3:  addi x10, x10, 22       # x10 = 15 + 22 = 37
        jalr x0,  x1,  0         # JALR: indirect return → branch to after3
after3:

        sb   x10, 16(x2)         # expected: 37
        jal  x0, done
done:   beq  x2, x2, done
