# test_trap.asm
.globl _start
_start:
    # 1. Trap Handler in mtvec eintragen
    la t0, trap_handler
    csrw mtvec, t0

    # 2. DER ABSTURZ
    .word 0xFFFFFFFF

    # ---------------------------------------------------------
    # 3. DAS ZIEL: Wenn mret funktioniert, landen wir HIER!
    # ---------------------------------------------------------
    # Testbench erfolgreich beenden (Der GPIO Hack)
    li t0, 0x100
    slli t0, t0, 24
    li t1, 6
    sb t1, 16(t0)

end_loop:
    j end_loop


# ==============================================================
# TRAP HANDLER
# ==============================================================
.align 4
trap_handler:
    csrr t1, mepc
    addi t1, t1, 4
    csrw mepc, t1
    mret