# RISC-V Assembly — UART0 RX test: receives and verifies "We will rock you."
# UART0 base 0x0000_0001_0000_0600; GPIO base 0x0000_0001_0000_0000
# Pass: GPIO[7:0] = 0x55    Fail: GPIO[7:0] = 0xFF
# TB must inject "We will rock you." (17 bytes) at CLKDIV=4 baud rate
# after firmware startup

.global _start

_start:
    addi  x1,  x0, 0x100
    slli  x1,  x1, 24          # x1  = GPIO base  = 0x0000_0001_0000_0000
    addi  x5,  x1, 0x600       # x5  = UART0 base = 0x0000_0001_0000_0600

    addi  x6,  x0, 4
    sd    x6,  16(x5)           # UART0.CLKDIV = 4 (must match TB inject rate)

    # Receive and verify "We will rock you." (17 bytes)
    addi  x11, x0, 0x57 ; jal x30, recv_char ; bne x10, x11, fail   # W
    addi  x11, x0, 0x65 ; jal x30, recv_char ; bne x10, x11, fail   # e
    addi  x11, x0, 0x20 ; jal x30, recv_char ; bne x10, x11, fail   # space
    addi  x11, x0, 0x77 ; jal x30, recv_char ; bne x10, x11, fail   # w
    addi  x11, x0, 0x69 ; jal x30, recv_char ; bne x10, x11, fail   # i
    addi  x11, x0, 0x6C ; jal x30, recv_char ; bne x10, x11, fail   # l
    addi  x11, x0, 0x6C ; jal x30, recv_char ; bne x10, x11, fail   # l
    addi  x11, x0, 0x20 ; jal x30, recv_char ; bne x10, x11, fail   # space
    addi  x11, x0, 0x72 ; jal x30, recv_char ; bne x10, x11, fail   # r
    addi  x11, x0, 0x6F ; jal x30, recv_char ; bne x10, x11, fail   # o
    addi  x11, x0, 0x63 ; jal x30, recv_char ; bne x10, x11, fail   # c
    addi  x11, x0, 0x6B ; jal x30, recv_char ; bne x10, x11, fail   # k
    addi  x11, x0, 0x20 ; jal x30, recv_char ; bne x10, x11, fail   # space
    addi  x11, x0, 0x79 ; jal x30, recv_char ; bne x10, x11, fail   # y
    addi  x11, x0, 0x6F ; jal x30, recv_char ; bne x10, x11, fail   # o
    addi  x11, x0, 0x75 ; jal x30, recv_char ; bne x10, x11, fail   # u
    addi  x11, x0, 0x2E ; jal x30, recv_char ; bne x10, x11, fail   # .

    addi  x10, x0, 0x55
    sb    x10, 16(x1)           # GPIO checkpoint = PASS
pass:
    jal   x0, pass

fail:
    addi  x10, x0, 0xFF
    sb    x10, 16(x1)           # GPIO checkpoint = FAIL
fail_loop:
    jal   x0, fail_loop

# ── recv_char ─────────────────────────────────────────────────
# Waits until RX FIFO is non-empty (FIFOSTAT[21]=rx_empty=0),
# then reads one byte from DATA into x10 (masked to 8 bits).
# Clobbers: x10.  Preserves: x1, x5, x11, x30.
recv_char:
rx_empty_wait:
    ld    x10, 48(x5)           # FIFOSTAT
    srli  x10, x10, 21          # bring rx_empty to bit 0
    andi  x10, x10, 1
    bne   x10, x0, rx_empty_wait
    ld    x10, 40(x5)           # DATA – pop byte from RX FIFO
    andi  x10, x10, 0xFF
    jalr  x0,  x30, 0
