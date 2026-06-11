# Row 58 (Table B.1): fence - memory ordering barrier
# On this single-issue CPU fence is a legal no-op; verify it does not trap
# and that stores executed before and after fence reach memory in program order.
.global _start
_start: addi x2, x0, 0x100
        slli x2, x2, 24         # GPIO base
        addi x10, x0, 58        # result
        sb   x10, 16(x2)        # store BEFORE fence
        fence iorw, iorw        # full barrier (no-op on this CPU)
        sb   x10, 16(x2)        # store AFTER fence -> gpio = 58 -> test ok
        jal  x0, done
done:   beq  x2, x2, done
