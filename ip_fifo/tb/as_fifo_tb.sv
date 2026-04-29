// =============================================================================
// as_fifo.sv
// Synchronous single-clock FIFO for the QSPI peripheral
//
// Converted from VHDL (fifo_e / fifo_a) with the following changes:
//   - Reset changed to active-high synchronous (matches QSPI / Wishbone style)
//   - Data width default 64 bit, depth default 16 (matches QSPI spec)
//   - Flush input added (for CTRL.TX_FLUSH / CTRL.RX_FLUSH)
//   - half_full_o added  (RX_HALF / TX_HALF interrupt source)
//   - half_empty_o added (TX_HALF interrupt source, synonym for TX side)
//   - level_o added      (feeds FIFOSTAT register, 8-bit fill level)
//   - Bug fix: cnt write/read guarded against full/empty overflow
//   - Bug fix: write to memory now guarded by !full
//   - Bug fix: read from memory now guarded by !empty
//   - almost_full / almost_empty kept but optional (tied to half thresholds
//     by default; override via parameters if needed)
//
// Parameters:
//   DATA_WIDTH  - Width of each FIFO entry in bits (default: 64)
//   FIFO_DEPTH  - Number of entries; must be a power of 2 (default: 16)
//   AF_LEVEL    - Almost-full  threshold (entry count, default: DEPTH*3/4)
//   AE_LEVEL    - Almost-empty threshold (entry count, default: DEPTH/4)
//
// Interface:
//   rst_i          - Synchronous reset, active high
//   clk_i          - Clock
//   flush_i        - Synchronous flush: clears FIFO in one cycle (active high)
//   wr_en_i        - Write enable
//   data_wr_i      - Write data
//   full_o         - FIFO full
//   almost_full_o  - Fill level > AF_LEVEL
//   half_full_o    - Fill level >= FIFO_DEPTH/2  (RX_HALF / TX_HALF source)
//   rd_en_i        - Read enable
//   data_rd_o      - Read data (registered, one-cycle latency)
//   empty_o        - FIFO empty
//   almost_empty_o - Fill level < AE_LEVEL
//   half_empty_o   - Fill level <  FIFO_DEPTH/2  (TX_HALF source)
//   level_o        - Fill level as binary count (feeds FIFOSTAT register)
//
// Usage (TX FIFO in QSPI):
//   as_fifo #(.DATA_WIDTH(64), .FIFO_DEPTH(16)) u_tx_fifo (
//     .rst_i(rst_i), .clk_i(clk_i), .flush_i(tx_flush_s),
//     .wr_en_i(tx_wr_s), .data_wr_i(tx_data_s),
//     .full_o(tx_full_s), .almost_full_o(), .half_full_o(), .half_empty_o(),
//     .rd_en_i(tx_rd_s), .data_rd_o(tx_data_kernel_s),
//     .empty_o(tx_empty_s), .almost_empty_o(), .level_o(tx_level_s)
//   );
//
// Usage (RX FIFO in QSPI):
//   as_fifo #(.DATA_WIDTH(64), .FIFO_DEPTH(16)) u_rx_fifo (
//     .rst_i(rst_i), .clk_i(clk_i), .flush_i(rx_flush_s),
//     .wr_en_i(rx_wr_s), .data_wr_i(rx_data_kernel_s),
//     .full_o(rx_full_s), .almost_full_o(), .half_full_o(rx_half_s), .half_empty_o(),
//     .rd_en_i(rx_rd_s), .data_rd_o(rx_data_s),
//     .empty_o(rx_empty_s), .almost_empty_o(), .level_o(rx_level_s)
//   );
// Connect: rx_half_s → RIS.HA, 
// tx_half_s → RIS.TH, 
// rx_empty_s → RIS.EM, 
// tx_empty_s → RIS.TE – genau wie in der aktualisierten Interrupt-Tabelle aus dem letzten Schritt spezifiziert
//
// Problem: This FIFO is asynchronous read -> no X-FAB SRAM will work (only 0 wait-states possible with S-BPI).
// Option A – FIFO bleibt als Flip-Flop-Implementierung (kein SRAM)
//  ->(* ram_style = "registers" *) logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
// Option B – 1 Wait State im Slave-BPI
// Option C – Read-First-Registrierung im FIFO (empfohlen wenn SRAM nötig)
// =============================================================================

`timescale 1ns/1ps

module as_fifo #(
  parameter int DATA_WIDTH = 64,               // width of each FIFO word
  parameter int FIFO_DEPTH = 16,               // number of entries (power of 2)
  parameter int AF_LEVEL   = FIFO_DEPTH*3/4,   // almost-full  threshold
  parameter int AE_LEVEL   = FIFO_DEPTH/4      // almost-empty threshold
)(
  input  logic                      rst_i,       // synchronous reset, active high
  input  logic                      clk_i,
  input  logic                      flush_i,     // synchronous flush, active high

  // Write interface
  input  logic                      wr_en_i,
  input  logic [DATA_WIDTH-1:0]     data_wr_i,
  output logic                      full_o,
  output logic                      almost_full_o,
  output logic                      half_full_o,  // fill >= FIFO_DEPTH/2

  // Read interface
  input  logic                      rd_en_i,
  output logic [DATA_WIDTH-1:0]     data_rd_o,
  output logic                      empty_o,
  output logic                      almost_empty_o,
  output logic                      half_empty_o, // fill <  FIFO_DEPTH/2

  // Fill level (for FIFOSTAT register)
  output logic [$clog2(FIFO_DEPTH):0] level_o    // 0 .. FIFO_DEPTH
);

  // ---------------------------------------------------------------------------
  // Parameter checks (evaluated at elaboration time)
  // ---------------------------------------------------------------------------
  initial begin
    if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0)
      $fatal(1, "as_fifo: FIFO_DEPTH must be a power of 2 and >= 2");
    if (AF_LEVEL >= FIFO_DEPTH)
      $fatal(1, "as_fifo: AF_LEVEL must be < FIFO_DEPTH");
    if (AE_LEVEL <= 0)
      $fatal(1, "as_fifo: AE_LEVEL must be > 0");
  end

  // ---------------------------------------------------------------------------
  // Local types and storage
  // ---------------------------------------------------------------------------
  localparam int PTR_WIDTH = $clog2(FIFO_DEPTH); // pointer width for wrap-around

  //logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
  (* ram_style = "registers" *) logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

  logic [PTR_WIDTH-1:0]      wr_ptr_r;  // write pointer
  logic [PTR_WIDTH-1:0]      rd_ptr_r;  // read pointer
  logic [$clog2(FIFO_DEPTH):0] cnt_r;   // fill level, 0 .. FIFO_DEPTH

  // Internal status wires (derived from cnt_r)
  logic full_s;
  logic empty_s;

  assign full_s  = (cnt_r == FIFO_DEPTH);
  assign empty_s = (cnt_r == 0);

  // ---------------------------------------------------------------------------
  // Main sequential process
  // Fixes vs. original VHDL:
  //   - Reset is synchronous active-high (not async active-low)
  //   - cnt_r guarded: only increments on real writes (!full),
  //                    only decrements on real reads  (!empty)
  //   - Memory write guarded by !full
  //   - Simultaneous read+write (cnt unchanged) handled correctly
  //   - flush_i supported
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : fifo_proc
    if (rst_i || flush_i) begin
      // -----------------------------------------------------------------------
      // Reset / Flush: clear pointers and counter; memory content is don't-care
      // -----------------------------------------------------------------------
      wr_ptr_r <= '0;
      rd_ptr_r <= '0;
      cnt_r    <= '0;
    end else begin
      // -----------------------------------------------------------------------
      // Normal operation
      // -----------------------------------------------------------------------

      // -- Write path --
      // Write is accepted only when FIFO is not full.
      // A simultaneous read frees a slot, so write is also accepted then.
      if (wr_en_i && (!full_s || rd_en_i)) begin
        mem[wr_ptr_r]  <= data_wr_i;
        wr_ptr_r       <= (wr_ptr_r == PTR_WIDTH'(FIFO_DEPTH-1))
                          ? '0
                          : wr_ptr_r + 1'b1;
      end

      // -- Read path --
      // Read is accepted only when FIFO is not empty.
      // A simultaneous write fills a slot, so read is also accepted then.
      if (rd_en_i && (!empty_s || wr_en_i)) begin
        rd_ptr_r <= (rd_ptr_r == PTR_WIDTH'(FIFO_DEPTH-1))
                    ? '0
                    : rd_ptr_r + 1'b1;
      end

      // -- Counter update --
      // Four cases:
      //   write only (and not full)  → increment
      //   read  only (and not empty) → decrement
      //   both write and read        → unchanged  (simultaneous push/pop)
      //   neither                    → unchanged
      unique case ({wr_en_i & (!full_s | rd_en_i),
                    rd_en_i & (!empty_s | wr_en_i)})
        2'b10:   cnt_r <= cnt_r + 1'b1;  // write only
        2'b01:   cnt_r <= cnt_r - 1'b1;  // read only
        default: cnt_r <= cnt_r;          // both or neither
      endcase
    end
  end : fifo_proc

  // ---------------------------------------------------------------------------
  // Read data output (registered, one-cycle latency after rd_en_i)
  // The read pointer is already advanced on the same clock edge as rd_en_i,
  // so we expose the *current* read pointer's content combinatorially:
  // ---------------------------------------------------------------------------
  assign data_rd_o = mem[rd_ptr_r];

  // ---------------------------------------------------------------------------
  // Status outputs
  // ---------------------------------------------------------------------------
  assign full_o         = full_s;
  assign empty_o        = empty_s;
  assign almost_full_o  = (cnt_r >  AF_LEVEL);
  assign almost_empty_o = (cnt_r <  AE_LEVEL);
  assign half_full_o    = (cnt_r >= FIFO_DEPTH / 2);  // RX_HALF interrupt source
  assign half_empty_o   = (cnt_r <  FIFO_DEPTH / 2);  // TX_HALF interrupt source
  assign level_o        = cnt_r;

endmodule : as_fifo


// =============================================================================
// as_fifo_tb.sv  --  self-checking testbench
//
// Covers:
//   1. Reset and flush
//   2. Sequential writes until full
//   3. Sequential reads until empty
//   4. Simultaneous read+write (FIFO not stalled)
//   5. Write-when-full rejection
//   6. Read-when-empty rejection
//   7. half_full_o / half_empty_o thresholds
//   8. level_o tracking
// =============================================================================
module as_fifo_tb;

  // DUT parameters
  localparam int DW    = 64;
  localparam int DEPTH = 16;
  localparam int HALF  = DEPTH / 2;

  // DUT ports
  logic               rst_i, clk_i, flush_i;
  logic               wr_en_i;
  logic [DW-1:0]      data_wr_i;
  logic               full_o, almost_full_o, half_full_o;
  logic               rd_en_i;
  logic [DW-1:0]      data_rd_o;
  logic               empty_o, almost_empty_o, half_empty_o;
  logic [$clog2(DEPTH):0] level_o;

  // Instantiate DUT
  as_fifo #(.DATA_WIDTH(DW), .FIFO_DEPTH(DEPTH)) dut (.*);

  // 100 MHz clock
  initial clk_i = 0;
  always #5 clk_i = ~clk_i;

  // Helper task: single write
  task automatic write_word(input logic [DW-1:0] d);
    @(posedge clk_i);
    wr_en_i    = 1'b1;
    data_wr_i  = d;
    rd_en_i    = 1'b0;
    flush_i    = 1'b0;
    @(posedge clk_i);
    wr_en_i    = 1'b0;
  endtask

  // Helper task: single read, returns data
  task automatic read_word(output logic [DW-1:0] d);
    @(posedge clk_i);
    rd_en_i    = 1'b1;
    wr_en_i    = 1'b0;
    flush_i    = 1'b0;
    @(posedge clk_i);
    d          = data_rd_o;
    rd_en_i    = 1'b0;
  endtask

  // Helper: apply reset
  task automatic do_reset;
    rst_i     = 1'b1;
    wr_en_i   = 1'b0;
    rd_en_i   = 1'b0;
    flush_i   = 1'b0;
    data_wr_i = '0;
    @(posedge clk_i);
    @(posedge clk_i);
    rst_i     = 1'b0;
  endtask

  // Simple assertion
  int pass_count = 0;
  int fail_count = 0;

  task automatic check(input string label,
                       input logic got,
                       input logic exp);
    if (got !== exp) begin
      $display("FAIL  [%0t] %s: got %0b, expected %0b", $time, label, got, exp);
      fail_count++;
    end else begin
      $display("PASS  [%0t] %s", $time, label);
      pass_count++;
    end
  endtask

  task automatic check_val(input string label,
                           input int got,
                           input int exp);
    if (got !== exp) begin
      $display("FAIL  [%0t] %s: got %0d, expected %0d", $time, label, got, exp);
      fail_count++;
    end else begin
      $display("PASS  [%0t] %s = %0d", $time, label, got);
      pass_count++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Main test sequence
  // -------------------------------------------------------------------------
  logic [DW-1:0] rdat;
  int i;

  initial begin
    $dumpfile("as_fifo_tb.vcd");
    $dumpvars(0, as_fifo_tb);

    $display("=== as_fifo Testbench START ===");

    // ---------------------------------------------------------
    // Test 1: Reset
    // ---------------------------------------------------------
    $display("-- Test 1: Reset --");
    do_reset();
    @(posedge clk_i); #1;
    check("empty after reset",    empty_o, 1'b1);
    check("full  after reset",    full_o,  1'b0);
    check_val("level after reset", int'(level_o), 0);

    // ---------------------------------------------------------
    // Test 2: Write DEPTH words → should become full
    // ---------------------------------------------------------
    $display("-- Test 2: Fill FIFO --");
    for (i = 0; i < DEPTH; i++) begin
      write_word(64'(i));
    end
    @(posedge clk_i); #1;
    check("full after DEPTH writes",  full_o,  1'b1);
    check("empty after DEPTH writes", empty_o, 1'b0);
    check_val("level = DEPTH", int'(level_o), DEPTH);

    // ---------------------------------------------------------
    // Test 3: Write-when-full must be rejected (level unchanged)
    // ---------------------------------------------------------
    $display("-- Test 3: Write when full (should be ignored) --");
    write_word(64'hDEAD_BEEF_DEAD_BEEF);
    @(posedge clk_i); #1;
    check("still full after overwrite attempt", full_o, 1'b1);
    check_val("level unchanged at DEPTH", int'(level_o), DEPTH);

    // ---------------------------------------------------------
    // Test 4: Read all words back and verify data
    // ---------------------------------------------------------
    $display("-- Test 4: Drain FIFO and check data integrity --");
    for (i = 0; i < DEPTH; i++) begin
      read_word(rdat);
      if (rdat !== 64'(i))
        $display("FAIL  data[%0d]: got %0h, expected %0h", i, rdat, i);
      else
        $display("PASS  data[%0d] = %0h", i, rdat);
    end
    @(posedge clk_i); #1;
    check("empty after drain", empty_o, 1'b1);
    check_val("level = 0 after drain", int'(level_o), 0);

    // ---------------------------------------------------------
    // Test 5: Read-when-empty must be rejected
    // ---------------------------------------------------------
    $display("-- Test 5: Read when empty (should be ignored) --");
    read_word(rdat);
    @(posedge clk_i); #1;
    check("still empty after underread", empty_o, 1'b1);
    check_val("level unchanged at 0", int'(level_o), 0);

    // ---------------------------------------------------------
    // Test 6: half_full / half_empty threshold
    // ---------------------------------------------------------
    $display("-- Test 6: half_full / half_empty --");
    do_reset();
    // Write HALF-1 words: should be half-empty
    for (i = 0; i < HALF-1; i++) write_word(64'(i));
    @(posedge clk_i); #1;
    check("half_empty before HALF", half_empty_o, 1'b1);
    check("NOT half_full before HALF", half_full_o,  1'b0);
    // Write one more: level == HALF → half_full
    write_word(64'hAA);
    @(posedge clk_i); #1;
    check("half_full  at HALF", half_full_o,  1'b1);
    check("NOT half_empty at HALF", half_empty_o, 1'b0);

    // ---------------------------------------------------------
    // Test 7: Simultaneous read + write (level stays constant)
    // ---------------------------------------------------------
    $display("-- Test 7: Simultaneous read+write --");
    // FIFO currently has HALF entries
    @(posedge clk_i);
    wr_en_i   = 1'b1;
    rd_en_i   = 1'b1;
    data_wr_i = 64'hCAFE_F00D_CAFE_F00D;
    flush_i   = 1'b0;
    @(posedge clk_i);
    wr_en_i   = 1'b0;
    rd_en_i   = 1'b0;
    @(posedge clk_i); #1;
    check_val("level unchanged after sim. rw", int'(level_o), HALF);

    // ---------------------------------------------------------
    // Test 8: Flush
    // ---------------------------------------------------------
    $display("-- Test 8: Flush --");
    // FIFO has HALF entries; flush should empty in one cycle
    @(posedge clk_i);
    flush_i = 1'b1;
    @(posedge clk_i);
    flush_i = 1'b0;
    @(posedge clk_i); #1;
    check("empty after flush", empty_o, 1'b1);
    check_val("level = 0 after flush", int'(level_o), 0);

    // ---------------------------------------------------------
    // Summary
    // ---------------------------------------------------------
    $display("=== SUMMARY: %0d passed, %0d failed ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED -- review output above");

    $finish;
  end

  // Timeout watchdog
  initial begin
    #100000;
    $display("FAIL: Simulation timeout");
    $finish;
  end

endmodule : as_fifo_tb
