# RISC-V Assembly — UART0 TX test: sends "Hello Rocker"
# UART0 base 0x0000_0001_0000_0600; GPIO base 0x0000_0001_0000_0000
# Pass: GPIO[7:0] = 0x55

.global _start

_start:
    addi  x1,  x0, 0x100
    slli  x1,  x1, 24          # x1  = GPIO base  = 0x0000_0001_0000_0000
    addi  x5,  x1, 0x600       # x5  = UART0 base = 0x0000_0001_0000_0600

    addi  x6,  x0, 4
    sd    x6,  16(x5)           # UART0.CLKDIV = 4 (fast baud for simulation)

    # Send "Hello Rocker" character by character
    addi  x10, x0, 0x48
    jal   x30, send_char        # H
    addi  x10, x0, 0x65
    jal   x30, send_char        # e
    addi  x10, x0, 0x6C
    jal   x30, send_char        # l
    addi  x10, x0, 0x6C
    jal   x30, send_char        # l
    addi  x10, x0, 0x6F
    jal   x30, send_char        # o
    addi  x10, x0, 0x20
    jal   x30, send_char        # space
    addi  x10, x0, 0x52
    jal   x30, send_char        # R
    addi  x10, x0, 0x6F
    jal   x30, send_char        # o
    addi  x10, x0, 0x63
    jal   x30, send_char        # c
    addi  x10, x0, 0x6B
    jal   x30, send_char        # k
    addi  x10, x0, 0x65
    jal   x30, send_char        # e
    addi  x10, x0, 0x72
    jal   x30, send_char        # r

    # Wait for the last character to finish transmitting
wait_tx_done:
    ld    x11, 32(x5)           # UART0.STATUS
    andi  x11, x11, 1           # bit 0 = tx_busy
    bne   x11, x0, wait_tx_done

    addi  x10, x0, 0x55
    sb    x10, 16(x1)           # GPIO checkpoint = PASS

done:
    jal   x0, done

# ── send_char ────────────────────────────────────────────────
# Waits until TX is not busy, then writes x10 to UART DATA.
# Clobbers: x11.  Preserves: x1, x5, x10, x30.
send_char:
tx_busy_wait:
    ld    x11, 32(x5)           # STATUS
    andi  x11, x11, 1           # tx_busy
    bne   x11, x0, tx_busy_wait
    sd    x10, 40(x5)           # DATA – push byte into TX FIFO
    jalr  x0,  x30, 0
