// =============================================================================
// tb_uart_top.sv  –  Testbench for as_uart_top (ip_uart_v2)
// =============================================================================
// T01 Reset defaults         T07 Even-parity loopback
// T02 Register R/W           T08 Parity error injection
// T03 TX loopback (1 byte)   T09 Frame error injection
// T04 TX loopback (4 bytes)  T10 tx_ready interrupt (initial state)
// T05 TX serial decode       T11 rx_ready threshold interrupt
// T06 RX serial inject       T12 FIFO flush
// =============================================================================
`timescale 1ns/1ps

import as_pack::*;

module tb_uart_top;

  localparam int CLK_PERIOD  = 8;        // ns  (125 MHz)
  localparam int TEST_CLKDIV = 4;        // baud divisor used in simulation
  localparam int BIT_PERIOD  = 16 * TEST_CLKDIV * CLK_PERIOD; // ns per UART bit
  localparam int FIFO_DEPTH  = 16;
  localparam int UART_AW     = 8;

  // Register offsets (must match as_uart_top)
  localparam int OFF_ID       =  0;
  localparam int OFF_LCR      =  8;
  localparam int OFF_CLKDIV   = 16;
  localparam int OFF_CTRL     = 24;
  localparam int OFF_STATUS   = 32;
  localparam int OFF_DATA     = 40;
  localparam int OFF_FIFOSTAT = 48;
  localparam int OFF_RXTHRES  = 56;
  localparam int OFF_RIS      = 64;
  localparam int OFF_IMSC     = 72;
  localparam int OFF_MIS      = 80;
  localparam int OFF_ICR      = 88;

  // ── Clock / reset ──────────────────────────────────────────────────────────
  logic clk_s = 1'b0;
  logic rst_s;
  always #(CLK_PERIOD/2) clk_s = ~clk_s;

  // ── Wishbone signals ────────────────────────────────────────────────────────
  logic [UART_AW-1:0] wb_addr_s;
  logic [63:0]        wb_wdat_s, wb_rdat_s;
  logic               wb_we_s, wb_stb_s, wb_ack_s, wb_cyc_s;
  logic [7:0]         wb_sel_s;

  // ── UART I/O ────────────────────────────────────────────────────────────────
  logic tx_s;          // DUT output — serial TX line
  logic rx_s = 1'b1;  // TB drives this — serial RX line (idle = 1)
  logic irq_s;

  // ── Test statistics ─────────────────────────────────────────────────────────
  int pass_cnt = 0;
  int fail_cnt = 0;

  // ── DUT ─────────────────────────────────────────────────────────────────────
  as_uart_top #(
    .UART_ADDR_WIDTH(UART_AW),
    .UART_DATA_WIDTH(64),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (
    .clk_i     (clk_s),
    .rst_i     (rst_s),
    .wbdAddr_i (wb_addr_s),
    .wbdDat_i  (wb_wdat_s),
    .wbdDat_o  (wb_rdat_s),
    .wbdWe_i   (wb_we_s),
    .wbdSel_i  (wb_sel_s),
    .wbdStb_i  (wb_stb_s),
    .wbdAck_o  (wb_ack_s),
    .wbdCyc_i  (wb_cyc_s),
    .tx_o      (tx_s),
    .rx_i      (rx_s),
    .uart_irq_o(irq_s)
  );

  // ============================================================================
  // Tasks
  // ============================================================================

  // Wishbone single write.
  // #1 after posedge places signal changes AFTER always_ff evaluation, avoiding
  // the active-region race in xsim where always_ff runs before task-blocking code.
  task automatic wb_write(input int unsigned addr, input logic [63:0] data);
    @(posedge clk_s); #1;       // drive after always_ff has evaluated
    wb_addr_s = UART_AW'(addr);
    wb_wdat_s = data;
    wb_we_s   = 1'b1;
    wb_stb_s  = 1'b1;
    wb_cyc_s  = 1'b1;
    wb_sel_s  = 8'hFF;
    @(posedge clk_s);            // DUT latches wr_s=1 at this edge
    #1;                          // deassert AFTER the latch
    wb_stb_s  = 1'b0;
    wb_cyc_s  = 1'b0;
    wb_we_s   = 1'b0;
  endtask

  // Wishbone single read.
  // Sample wb_rdat_s AT the posedge (before NBA), so FIFO combinatorial
  // data_rd_o still shows mem[rd_ptr_r_OLD].  Deasserting stb one #1 later
  // ensures exactly one FIFO pop (pointer advances at this posedge only).
  task automatic wb_read(input int unsigned addr, output logic [63:0] data);
    @(posedge clk_s); #1;       // drive after always_ff
    wb_addr_s = UART_AW'(addr);
    wb_we_s   = 1'b0;
    wb_stb_s  = 1'b1;
    wb_cyc_s  = 1'b1;
    wb_sel_s  = 8'hFF;
    @(posedge clk_s);            // rd_ptr advances (NBA); sample BEFORE that
    data      = wb_rdat_s;       // mem[OLD_rd_ptr] — correct FIFO head
    #1;
    wb_stb_s  = 1'b0;
    wb_cyc_s  = 1'b0;
  endtask

  // Assertion helper
  task automatic check(input logic cond, input string name);
    if (cond) begin
      $display("  PASS  %s", name);
      pass_cnt++;
    end else begin
      $display("  FAIL  %s", name);
      fail_cnt++;
    end
  endtask

  // Inject one UART frame onto rx_s (LSB first, LCR-compatible)
  //   parity_mode: 0=none  1=odd  2=even
  task automatic rx_send(
    input logic [7:0] data,
    input int         data_bits,
    input int         parity_mode,
    input int         stop_bits
  );
    logic par = 1'b0;
    int   i;
    for (i = 0; i < data_bits; i++) par ^= data[i];
    if (parity_mode == 1) par = ~par;   // odd: complement
    // start bit
    rx_s = 1'b0; #(BIT_PERIOD);
    // data bits
    for (i = 0; i < data_bits; i++) begin
      rx_s = data[i]; #(BIT_PERIOD);
    end
    // parity bit
    if (parity_mode != 0) begin
      rx_s = par; #(BIT_PERIOD);
    end
    // stop bit(s)
    rx_s = 1'b1;
    for (int si = 0; si < stop_bits; si++) #(BIT_PERIOD);
  endtask

  // Inject frame with deliberate wrong parity (for parity error test)
  task automatic rx_send_bad_parity(input logic [7:0] data, input int data_bits,
                                    input int parity_mode);
    logic par = 1'b0;
    int   i;
    for (i = 0; i < data_bits; i++) par ^= data[i];
    if (parity_mode == 1) par = ~par;
    par = ~par;   // flip parity → error
    rx_s = 1'b0; #(BIT_PERIOD);
    for (i = 0; i < data_bits; i++) begin
      rx_s = data[i]; #(BIT_PERIOD);
    end
    rx_s = par; #(BIT_PERIOD);
    rx_s = 1'b1; #(BIT_PERIOD);
  endtask

  // Inject frame with stop bit forced low (frame error)
  task automatic rx_send_frame_err(input logic [7:0] data, input int data_bits);
    int i;
    rx_s = 1'b0; #(BIT_PERIOD);
    for (i = 0; i < data_bits; i++) begin
      rx_s = data[i]; #(BIT_PERIOD);
    end
    rx_s = 1'b0; #(BIT_PERIOD * 2);   // low stop bit + recovery
    rx_s = 1'b1; #(BIT_PERIOD);
  endtask

  // Monitor tx_s: wait for start bit, decode one 8N1 frame; return byte
  task automatic tx_recv_8n1(output logic [7:0] rx_data, output logic frame_err);
    int i;
    @(negedge tx_s);                     // start bit falling edge
    #(BIT_PERIOD / 2);                   // advance to centre of start bit
    frame_err = 1'b0;
    rx_data   = 8'h00;
    for (i = 0; i < 8; i++) begin
      #(BIT_PERIOD);
      rx_data[i] = tx_s;
    end
    #(BIT_PERIOD);                       // stop bit
    if (tx_s !== 1'b1) frame_err = 1'b1;
  endtask

  // ============================================================================
  // Main test sequence
  // ============================================================================
  initial begin
    // Initialise WB bus to idle
    {wb_stb_s, wb_cyc_s, wb_we_s} = 3'b000;
    wb_addr_s = '0; wb_wdat_s = '0; wb_sel_s = 8'hFF;

    // Reset
    rst_s = 1'b1;
    repeat(4) @(posedge clk_s);
    rst_s = 1'b0;
    repeat(2) @(posedge clk_s);

    // Set fast baud rate for simulation
    wb_write(OFF_CLKDIV, 64'(TEST_CLKDIV));

    // ────────────────────────────────────────────────────────────────────────
    // T01: Reset defaults
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT01  Reset defaults");
      wb_read(OFF_ID,       rd); check(rd         == 64'h20, "ID = 0x20");
      wb_read(OFF_LCR,      rd); check(rd[5:0]    == 6'h03,  "LCR = 8N1");
      wb_read(OFF_CLKDIV,   rd); check(rd[15:0]   == 16'(TEST_CLKDIV), "CLKDIV written");
      wb_read(OFF_CTRL,     rd); check(rd         == 64'h0,  "CTRL = 0");
      wb_read(OFF_RIS,      rd); check(rd[6:3]    == 4'h0,   "RIS error bits [6:3] = 0");
      wb_read(OFF_STATUS,   rd); check(rd[0]      == 1'b0,   "TX not busy");
      wb_read(OFF_STATUS,   rd); check(rd[1]      == 1'b0,   "RX not busy");
      wb_read(OFF_FIFOSTAT, rd); check(rd[5]      == 1'b1,   "TX FIFO empty");
      wb_read(OFF_FIFOSTAT, rd); check(rd[21]     == 1'b1,   "RX FIFO empty");
    end

    // ────────────────────────────────────────────────────────────────────────
    // T02: Register R/W
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT02  Register R/W");
      // LCR: 7-bit, even parity, 2 stop = 0b100 10 11 → STOP=1, PAR=10, BITS=11 → 0x17... wait
      // [1:0]=11=8bit, [3:2]=10=even, [4]=1=2stop, [5]=0 → 0b0_1_10_11 = 0x1B
      wb_write(OFF_LCR, 64'h1B);
      wb_read (OFF_LCR, rd); check(rd[5:0] == 6'h1B, "LCR R/W 8E2");
      wb_write(OFF_LCR, 64'h03);             // restore 8N1

      wb_write(OFF_RXTHRES, 64'h5);
      wb_read (OFF_RXTHRES, rd); check(rd[4:0] == 5'h5, "RXTHRES R/W");
      wb_write(OFF_RXTHRES, 64'h8);          // restore default

      wb_write(OFF_IMSC, 64'h7F);
      wb_read (OFF_IMSC, rd); check(rd[6:0] == 7'h7F, "IMSC R/W");
      wb_write(OFF_IMSC, 64'h0);

      // CLKDIV = 0 must be rejected
      wb_write(OFF_CLKDIV, 64'h0);
      wb_read (OFF_CLKDIV, rd); check(rd[15:0] == 16'(TEST_CLKDIV), "CLKDIV 0 rejected");

      // ICR reads as 0 (write-only)
      wb_read(OFF_ICR, rd); check(rd == 64'h0, "ICR reads 0");
    end

    // ────────────────────────────────────────────────────────────────────────
    // T03: TX loopback — single byte 8N1
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT03  TX loopback single byte 8N1");
      wb_write(OFF_CTRL, 64'h1);
      wb_write(OFF_DATA, 64'hA5);
      #(14 * BIT_PERIOD);
      wb_read(OFF_STATUS,   rd); check(rd[0] == 1'b0,  "TX idle");
      wb_read(OFF_FIFOSTAT, rd); check(rd[21] == 1'b0, "RX not empty");
      wb_read(OFF_DATA,     rd); check(rd[7:0] == 8'hA5, "RX = 0xA5");
      wb_read(OFF_FIFOSTAT, rd); check(rd[21] == 1'b1, "RX empty after pop");
      wb_write(OFF_CTRL, 64'h0);
    end

    // ────────────────────────────────────────────────────────────────────────
    // T04: TX loopback — four bytes in sequence
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT04  TX loopback 4 bytes");
      wb_write(OFF_CTRL, 64'h1);
      wb_write(OFF_DATA, 64'h11);
      wb_write(OFF_DATA, 64'h22);
      wb_write(OFF_DATA, 64'h33);
      wb_write(OFF_DATA, 64'h44);
      #(50 * BIT_PERIOD);
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'h11, "seq byte 0 = 0x11");
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'h22, "seq byte 1 = 0x22");
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'h33, "seq byte 2 = 0x33");
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'h44, "seq byte 3 = 0x44");
      wb_write(OFF_CTRL, 64'h0);
    end

    // ────────────────────────────────────────────────────────────────────────
    // T05: TX serial decode — verify bit pattern on tx_s pin
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [7:0] rx_data;
      logic       ferr;
      $display("\nT05  TX serial decode (0x55, 8N1)");
      fork
        wb_write(OFF_DATA, 64'h55);
        tx_recv_8n1(rx_data, ferr);
      join
      check(rx_data == 8'h55, "TX serial = 0x55");
      check(ferr == 1'b0,     "no frame error on TX pin");

      $display("\nT05b TX serial decode (0xAA, 8N1)");
      fork
        wb_write(OFF_DATA, 64'hAA);
        tx_recv_8n1(rx_data, ferr);
      join
      check(rx_data == 8'hAA, "TX serial = 0xAA");
    end

    // ────────────────────────────────────────────────────────────────────────
    // T06: RX serial inject — 8N1
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT06  RX serial inject (8N1)");
      rx_send(8'hC3, 8, 0, 1);
      repeat(6) @(posedge clk_s);
      wb_read(OFF_FIFOSTAT, rd); check(rd[21] == 1'b0, "RX has data after inject");
      wb_read(OFF_DATA,     rd); check(rd[7:0] == 8'hC3, "RX = 0xC3");

      rx_send(8'h5A, 8, 0, 1);
      repeat(6) @(posedge clk_s);
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'h5A, "RX = 0x5A");
    end

    // ────────────────────────────────────────────────────────────────────────
    // T07: Even parity — loopback 8E1
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      // LCR: [1:0]=11(8bit), [3:2]=10(even), [4]=0(1stop), [5]=0 → 0x0B
      $display("\nT07  Even parity loopback 8E1");
      wb_write(OFF_LCR,  64'h0B);
      wb_write(OFF_CTRL, 64'h1);
      // 0xAA = 10101010 → XOR=0 → even parity bit = 0
      wb_write(OFF_DATA, 64'hAA);
      #(16 * BIT_PERIOD);
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'hAA, "8E1 loopback 0xAA");
      wb_read(OFF_RIS,  rd); check(rd[4] == 1'b0,    "no parity err on 0xAA");
      // 0xFF = 11111111 → XOR=0 → even parity bit = 0
      wb_write(OFF_DATA, 64'hFF);
      #(16 * BIT_PERIOD);
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'hFF, "8E1 loopback 0xFF");
      wb_read(OFF_RIS,  rd); check(rd[4] == 1'b0,    "no parity err on 0xFF");
      wb_write(OFF_CTRL, 64'h0);
      wb_write(OFF_LCR,  64'h03);   // restore 8N1
    end

    // ────────────────────────────────────────────────────────────────────────
    // T08: Parity error injection (8E1, wrong parity bit injected on rx_s)
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT08  Parity error injection (8E1)");
      wb_write(OFF_LCR,  64'h0B);  // 8E1
      wb_write(OFF_IMSC, 64'h10);  // enable parity_err interrupt
      rx_send_bad_parity(8'h81, 8, 2);   // 8E, wrong parity
      repeat(6) @(posedge clk_s);
      wb_read(OFF_RIS, rd); check(rd[4] == 1'b1, "RIS.parity_err set");
      wb_read(OFF_MIS, rd); check(rd[4] == 1'b1, "MIS.parity_err set");
      check(irq_s,          "IRQ asserted on parity error");
      wb_write(OFF_ICR, 64'h10);          // clear parity_err
      repeat(2) @(posedge clk_s);
      wb_read(OFF_RIS, rd); check(rd[4] == 1'b0, "RIS.parity_err cleared");
      check(!irq_s,         "IRQ deasserted after ICR");
      // drain the erroneous byte from RX FIFO
      wb_write(OFF_CTRL, 64'h4);   // rx_flush
      wb_write(OFF_IMSC, 64'h0);
      wb_write(OFF_LCR,  64'h03);  // restore 8N1
    end

    // ────────────────────────────────────────────────────────────────────────
    // T09: Frame error — bad stop bit on rx_s
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT09  Frame error (bad stop bit)");
      wb_write(OFF_IMSC, 64'h8);    // enable frame_err interrupt
      rx_send_frame_err(8'h7E, 8);
      repeat(6) @(posedge clk_s);
      wb_read(OFF_RIS, rd); check(rd[3] == 1'b1, "RIS.frame_err set");
      wb_read(OFF_MIS, rd); check(rd[3] == 1'b1, "MIS.frame_err set");
      check(irq_s,          "IRQ asserted on frame error");
      wb_write(OFF_ICR, 64'h8);
      repeat(2) @(posedge clk_s);
      wb_read(OFF_RIS, rd); check(rd[3] == 1'b0, "RIS.frame_err cleared");
      wb_write(OFF_CTRL, 64'h4);    // rx_flush
      wb_write(OFF_IMSC, 64'h0);
    end

    // ────────────────────────────────────────────────────────────────────────
    // T10: tx_ready interrupt — TX FIFO below threshold after reset
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT10  tx_ready interrupt initial state");
      // After reset TX FIFO is empty (0 < 8 = RXTHRES) → tx_ready_s rises
      // on first clock → RIS[1] already set
      wb_read(OFF_RIS, rd); check(rd[1] == 1'b1, "RIS.tx_ready set (FIFO empty)");
      wb_write(OFF_IMSC, 64'h2);
      wb_read(OFF_MIS, rd); check(rd[1] == 1'b1, "MIS.tx_ready set");
      check(irq_s,          "IRQ asserted on tx_ready");
      wb_write(OFF_IMSC, 64'h0);
    end

    // ────────────────────────────────────────────────────────────────────────
    // T11: rx_ready threshold interrupt
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT11  rx_ready threshold interrupt (RXTHRES=3)");
      wb_write(OFF_RXTHRES, 64'h3);
      wb_write(OFF_IMSC,    64'h1);  // enable rx_ready
      wb_write(OFF_ICR,     64'h1);  // clear any stale rx_ready in RIS

      rx_send(8'hAB, 8, 0, 1);      // byte 1
      repeat(4) @(posedge clk_s);
      rx_send(8'hCD, 8, 0, 1);      // byte 2
      repeat(4) @(posedge clk_s);
      wb_read(OFF_RIS, rd); check(rd[0] == 1'b0, "RIS.rx_ready 0 (level 2 < 3)");

      rx_send(8'hEF, 8, 0, 1);      // byte 3 — reaches threshold
      repeat(4) @(posedge clk_s);
      wb_read(OFF_RIS, rd); check(rd[0] == 1'b1, "RIS.rx_ready 1 (level 3 >= 3)");
      check(irq_s,          "IRQ asserted on rx_ready");

      // Drain FIFO
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'hAB, "RX drain byte 0");
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'hCD, "RX drain byte 1");
      wb_read(OFF_DATA, rd); check(rd[7:0] == 8'hEF, "RX drain byte 2");
      wb_write(OFF_ICR,     64'h1);
      wb_write(OFF_IMSC,    64'h0);
      wb_write(OFF_RXTHRES, 64'h8);  // restore
    end

    // ────────────────────────────────────────────────────────────────────────
    // T12: FIFO flush
    // ────────────────────────────────────────────────────────────────────────
    begin
      logic [63:0] rd;
      $display("\nT12  FIFO flush");
      // Push 3 bytes to TX FIFO (no loopback — TX transmits externally)
      wb_write(OFF_DATA, 64'hDE);
      wb_write(OFF_DATA, 64'hAD);
      wb_write(OFF_DATA, 64'hBE);
      wb_read(OFF_FIFOSTAT, rd); check(rd[4:0] >= 5'd1, "TX FIFO non-empty before flush");
      wb_write(OFF_CTRL, 64'h2);   // tx_flush (bit 1)
      repeat(2) @(posedge clk_s);
      wb_read(OFF_FIFOSTAT, rd); check(rd[5] == 1'b1, "TX empty after tx_flush");

      // Inject 2 bytes via RX
      rx_send(8'h12, 8, 0, 1);
      rx_send(8'h34, 8, 0, 1);
      repeat(4) @(posedge clk_s);
      wb_read(OFF_FIFOSTAT, rd); check(rd[21] == 1'b0, "RX has data before flush");
      wb_write(OFF_CTRL, 64'h4);   // rx_flush (bit 2)
      repeat(2) @(posedge clk_s);
      wb_read(OFF_FIFOSTAT, rd); check(rd[21] == 1'b1, "RX empty after rx_flush");

      // Wait for any in-flight TX frame to complete
      #(15 * BIT_PERIOD);
    end

    // ────────────────────────────────────────────────────────────────────────
    // Summary
    // ────────────────────────────────────────────────────────────────────────
    $display("\n====================================");
    $display("  PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
    $display("====================================");
    if (fail_cnt == 0) $display("  ALL TESTS PASSED");
    else               $display("  *** FAILURES DETECTED ***");
    $finish;
  end

  // Watchdog
  initial begin
    #5_000_000;
    $display("WATCHDOG: simulation did not finish in 5 ms");
    $finish;
  end

endmodule : tb_uart_top
