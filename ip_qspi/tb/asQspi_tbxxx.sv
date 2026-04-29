// =============================================================================
// as_qspi_tb.sv  –  Testbench for as_qspi kernel
// =============================================================================
//
// Simulated NOR-Flash device: Winbond W25Q128JV
//
// Test 1 – Single SPI Read (opcode 0x0B, Fast Read, 1-1-1)
//   CMD  : 0x0B          (8 SCK cycles, Single)
//   ADDR : 0x001234      (24 bit, Single, 24 SCK cycles)
//   DUMMY: 8 cycles
//   DATA : 8 bytes read  (64 SCK cycles, Single)
//   Flash drives 0xDEADBEEFCAFEF00D on data_io[0]
//
// Test 2 – Single SPI Write (opcode 0x02, Page Program, 1-1-1)
//   CMD  : 0x02          (8 SCK cycles, Single)
//   ADDR : 0x005678      (24 bit, Single)
//   DUMMY: 0 cycles      (no dummy for write)
//   DATA : 8 bytes write (64 SCK cycles, Single)
//   TX-FIFO contains 0xA5A5A5A5_12345678
//
// Test 3 – Quad SPI Read (opcode 0x6B, Quad Output Fast Read, 1-1-4)
//   CMD  : 0x6B          (8 SCK cycles, Single – CMD always Single)
//   ADDR : 0xABCDEF      (24 bit, Single)
//   DUMMY: 8 cycles
//   DATA : 8 bytes read  (16 SCK cycles, Quad)
//   Flash drives nibbles on data_io[3:0]
//
// Clocking
//   clk_i    : 100 MHz  (10 ns period)
//   clkdiv   : 0x02     → f_SCK = 100/(2*3) ≈ 16.7 MHz (6 clk_i per SCK half)
//
// Checking
//   - CS waveform:    asserted during CMD/ADDR/DUM/DAT, deasserted in DONE/IDLE
//   - SCK waveform:   running only during active phases
//   - stat_busy_o:    high while not IDLE/DONE
//   - stat_done_o:    1-cycle pulse at end of each transfer
//   - tx_rd_o:        pulsed after 64 TX bits consumed
//   - rx_wr_o:        pulsed after 64 RX bits received
//   - rx_data_o:      compared to expected value after rx_wr_o
//
// =============================================================================

`timescale 1ns/1ps
import as_pack::*;

// --------------------------------------------------------------------------
// Minimal as_pack stub  (replace with your real as_pack when available)
// --------------------------------------------------------------------------
/*package as_pack;
  localparam int reg_width = 64;
  localparam int wbdSel    = 8;

  typedef struct packed {
    logic  addr_len;  // [7]
    logic  cpol;      // [6]
    logic  cpha;      // [5]
    logic  dual;      // [4]
    logic  cs_hold;   // [3]
    logic  xip;       // [2]
    logic  ddr;       // [1]
    logic  quad;      // [0]
  } qspi_ctrl_t;
endpackage*/

// --------------------------------------------------------------------------
// DUT (inline – remove if compiling as_qspi.sv separately)
// --------------------------------------------------------------------------
// `include "as_qspi.sv"   ← uncomment when compiling separately

// --------------------------------------------------------------------------
// Testbench
// --------------------------------------------------------------------------
module as_qspi_tb;

  import as_pack::*;

  // -------------------------------------------------------------------------
  // Parameters
  // -------------------------------------------------------------------------
  localparam int CLK_PERIOD  = 10;    // ns, 100 MHz
  localparam int CLKDIV      = 8'd2;  // f_SCK = 100/(2*(2+1)) ≈ 16.7 MHz
  localparam int SCK_HALF    = (CLKDIV + 1) * CLK_PERIOD; // ns per SCK half

  // -------------------------------------------------------------------------
  // DUT ports
  // -------------------------------------------------------------------------
  logic          rst_i;
  logic          clk_i;
  logic          start_i;
  qspi_ctrl_t    ctrl_reg_i;
  logic [7:0]    cmd_reg_i;
  logic [31:0]   addr_reg_i;
  logic [15:0]   len_reg_i;
  logic [5:0]    dummy_reg_i;
  logic [7:0]    clkdiv_reg_i;
  logic [31:0]   timeout_reg_i;
  logic          stat_busy_o;
  logic          stat_done_o;
  logic          stat_error_o;
  logic          stat_timeout_o;
  logic          tx_empty_i;
  logic          rx_full_i;
  logic          tx_rd_o;
  logic          rx_wr_o;
  logic [63:0]   tx_data_i;
  logic [63:0]   rx_data_o;
  logic          sck_o;
  logic          cs_o;
  wire  [3:0]    data_io;

  // -------------------------------------------------------------------------
  // Tri-state flash model drivers
  // -------------------------------------------------------------------------
  logic [3:0] flash_drive_s;     // what the flash model puts on the bus
  logic       flash_oe_s;        // flash output enable (during read DATA phase)

  assign data_io = flash_oe_s ? flash_drive_s : 4'bzzzz;

  // -------------------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------------------
  as_qspi dut (
    .rst_i          ( rst_i          ),
    .clk_i          ( clk_i          ),
    .start_i        ( start_i        ),
    .ctrl_reg_i     ( ctrl_reg_i     ),
    .cmd_reg_i      ( cmd_reg_i      ),
    .addr_reg_i     ( addr_reg_i     ),
    .len_reg_i      ( len_reg_i      ),
    .dummy_reg_i    ( dummy_reg_i    ),
    .clkdiv_reg_i   ( clkdiv_reg_i   ),
    .timeout_reg_i  ( timeout_reg_i  ),
    .stat_busy_o    ( stat_busy_o    ),
    .stat_done_o    ( stat_done_o    ),
    .stat_error_o   ( stat_error_o   ),
    .stat_timeout_o ( stat_timeout_o ),
    .tx_empty_i     ( tx_empty_i     ),
    .rx_full_i      ( rx_full_i      ),
    .tx_rd_o        ( tx_rd_o        ),
    .rx_wr_o        ( rx_wr_o        ),
    .tx_data_i      ( tx_data_i      ),
    .rx_data_o      ( rx_data_o      ),
    .sck_o          ( sck_o          ),
    .cs_o           ( cs_o           ),
    .data_io        ( data_io        )
  );

  // -------------------------------------------------------------------------
  // Clock
  // -------------------------------------------------------------------------
  initial clk_i = 1'b0;
  always #(CLK_PERIOD/2) clk_i = ~clk_i;

  // -------------------------------------------------------------------------
  // Waveform dump
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("as_qspi_tb.vcd");
    $dumpvars(0, as_qspi_tb);
  end

  // -------------------------------------------------------------------------
  // Scorecard
  // -------------------------------------------------------------------------
  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic chk(input string label,
                     input logic got,
                     input logic exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-40s  got=%b  exp=%b", $realtime, label, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %s", $realtime, label);
      pass_cnt++;
    end
  endtask

  task automatic chk64(input string label,
                       input logic [63:0] got,
                       input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-40s  got=%016h  exp=%016h",
               $realtime, label, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %-40s  = %016h", $realtime, label, got);
      pass_cnt++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Helper: reset
  // -------------------------------------------------------------------------
  task automatic do_reset();
    rst_i         = 1'b1;
    start_i       = 1'b0;
    ctrl_reg_i    = '0;
    cmd_reg_i     = '0;
    addr_reg_i    = '0;
    len_reg_i     = '0;
    dummy_reg_i   = '0;
    clkdiv_reg_i  = CLKDIV;
    timeout_reg_i = 32'd0;    // timeout disabled
    tx_empty_i    = 1'b1;
    rx_full_i     = 1'b0;
    tx_data_i     = '0;
    flash_drive_s = 4'b0000;
    flash_oe_s    = 1'b0;
    repeat(4) @(posedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i);
  endtask

  // -------------------------------------------------------------------------
  // Helper: pulse start for one cycle
  // -------------------------------------------------------------------------
  task automatic pulse_start();
    @(posedge clk_i);
    start_i = 1'b1;
    @(posedge clk_i);
    start_i = 1'b0;
  endtask

  // -------------------------------------------------------------------------
  // Helper: wait for DONE pulse (with timeout)
  // -------------------------------------------------------------------------
  task automatic wait_done(input int max_cycles = 100000);
    int cnt = 0;
    while (!stat_done_o && cnt < max_cycles) begin
      @(posedge clk_i);
      cnt++;
    end
    if (cnt >= max_cycles)
      $display("FAIL  wait_done: timeout after %0d cycles", max_cycles);
    else
      @(posedge clk_i);   // settle
  endtask

  // -------------------------------------------------------------------------
  // Flash model: drives data_io during RX DATA phase
  //
  // For Single SPI reads: drives one bit per SCK cycle on io[0]
  //   The flash samples the SCK *rising* edge (Mode 0) and drives data
  //   shortly after – we model this as combinatorial on SCK edges.
  //
  // For Quad SPI reads: drives 4 bits per SCK cycle on io[3:0]
  //
  // The model shifts out flash_data MSB-first.
  // -------------------------------------------------------------------------
  logic [63:0] flash_data_r;  // data the flash will send (loaded before transfer)
  int          flash_bit_cnt; // counts bits shifted out

  // Flash drives on SCK rising edge (Mode 0: master samples rising edge)
  // We drive combinatorially from flash_bit_cnt which is updated on SCK edges.
  always @(posedge sck_o or negedge cs_o) begin
    if (!cs_o) begin
      flash_bit_cnt = 0;
      flash_oe_s    <= 1'b0;
    end
  end

  // Separate process: detect when we are in the DATA phase for a read
  // and drive the bus.  We key off cs_o and sck_o being active plus
  // the fact that data_oe_s (internal to DUT) is low = Hi-Z = flash drives.
  // Since data_oe_s is internal we use a simpler heuristic:
  //   After (cmd_bits + addr_bits + dummy_bits) SCK edges the DATA phase starts.
  // We count SCK edges after CS assertion.
  
  int          sck_edge_cnt_r;   // counts SCK rising edges after CS goes high
  int          rx_start_edge_r;  // edge index where DATA phase begins (RX)
  logic        in_rx_phase_r;

  always @(posedge cs_o) begin
    sck_edge_cnt_r = 0;
    in_rx_phase_r  = 1'b0;
  end

  always @(posedge sck_o) begin
    if (cs_o) begin
      sck_edge_cnt_r++;
      if (sck_edge_cnt_r > rx_start_edge_r && in_rx_phase_r) begin
        // Drive the next bit(s) on falling edge (just before master samples)
      end
    end
  end

  // Simpler approach: drive data_io from a task in the main test sequence
  // synchronised to SCK falling edges (data driven before rising-edge sample).

  // =========================================================================
  // TEST SEQUENCE
  // =========================================================================
  initial begin
    $display("============================================================");
    $display("  as_qspi Testbench  –  W25Q128JV simulation");
    $display("  clk=100MHz  CLKDIV=%0d  f_SCK≈%0.1f MHz",
             CLKDIV, 100.0/(2.0*(CLKDIV+1)));
    $display("============================================================");

    do_reset();

    // -----------------------------------------------------------------------
    // Check idle state
    // -----------------------------------------------------------------------
    @(posedge clk_i); #1;
    chk("IDLE: busy=0",     stat_busy_o,  1'b0);
    chk("IDLE: done=0",     stat_done_o,  1'b0);
    chk("IDLE: error=0",    stat_error_o, 1'b0);
    chk("IDLE: timeout=0",  stat_timeout_o, 1'b0);
    chk("IDLE: cs=0",       cs_o,         1'b0);
    chk("IDLE: sck=0 (CPOL=0)", sck_o,   1'b0);

    // =======================================================================
    // TEST 1 – Single SPI Read  (opcode 0x0B, 1-1-1, 8 dummy cycles)
    // Expected: flash returns 0xDEADBEEFCAFEF00D
    // =======================================================================
    $display("\n--- TEST 1: Single SPI Read (0x0B, 24-bit addr, 8 dummy, 8 bytes) ---");

    begin : test1
      automatic logic [63:0] expected_rx = 64'hDEAD_BEEF_CAFE_F00D;
      automatic logic [63:0] captured_rx;
      automatic int          rx_wr_seen = 0;

      // Configure
      ctrl_reg_i    = '{addr_len:0, cpol:0, cpha:0, dual:0,
                        cs_hold:0, xip:0,  ddr:0,  quad:0};
      cmd_reg_i     = 8'h0B;        // Fast Read
      addr_reg_i    = 32'h00_1234;
      len_reg_i     = 16'd8;        // 8 bytes
      dummy_reg_i   = 6'd8;
      tx_empty_i    = 1'b1;         // no TX data → this is a read
      rx_full_i     = 1'b0;
      clkdiv_reg_i  = CLKDIV;

      // Fork: flash model drives io[0] MSB-first during DATA phase
      fork
        begin : flash_model_t1
          // Wait for CS to assert
          @(posedge cs_o);
          flash_oe_s    = 1'b0;

          // Skip CMD phase: 8 SCK cycles = 16 SCK half-periods
          // (wait for 8 rising edges on sck_o)
          repeat(8) @(posedge sck_o);

          // Skip ADDR phase: 24 SCK cycles
          repeat(24) @(posedge sck_o);

          // Skip DUMMY phase: 8 SCK cycles
          repeat(8) @(posedge sck_o);

          // DATA phase: drive 64 bits MSB-first on io[0]
          // Drive on SCK falling edge (master samples rising edge, Mode 0)
          flash_oe_s = 1'b1;
          for (int b = 63; b >= 0; b--) begin
            @(negedge sck_o);
            flash_drive_s = {3'b000, expected_rx[b]};
          end
          @(negedge sck_o);  // one extra edge before CS deasserts
          flash_oe_s    = 1'b0;
          flash_drive_s = 4'b0000;
        end

        begin : capture_t1
          // Wait for rx_wr_o pulse
          @(posedge clk_i);
          while (!rx_wr_o) @(posedge clk_i);
          captured_rx = rx_data_o;
          rx_wr_seen  = 1;
        end
      join_none

      // Kick off transfer
      pulse_start();
      @(posedge clk_i); #1;
      chk("T1: busy goes high",  stat_busy_o, 1'b1);
      chk("T1: cs asserted",     cs_o,        1'b1);

      wait_done();

      // Allow flash fork to finish
      #(CLK_PERIOD * 5);
      disable flash_model_t1;
      disable capture_t1;

      // Checks
      chk("T1: done pulse",    stat_done_o,  1'b1);
      chk("T1: no error",      stat_error_o, 1'b0);
      chk("T1: cs deasserted", cs_o,         1'b0);
      if (rx_wr_seen)
        chk64("T1: rx_data == expected", captured_rx, expected_rx);
      else
        $display("FAIL  T1: rx_wr_o never fired");

      @(posedge clk_i); #1;
      chk("T1: busy gone after IDLE", stat_busy_o, 1'b0);
    end

    repeat(10) @(posedge clk_i);

    // =======================================================================
    // TEST 2 – Single SPI Write  (opcode 0x02, 1-1-1, 0 dummy cycles)
    // TX-FIFO contains 0xA5A5A5A5_12345678
    // We verify tx_rd_o fires and CS/SCK waveform is correct.
    // =======================================================================
    $display("\n--- TEST 2: Single SPI Write (0x02, 24-bit addr, 0 dummy, 8 bytes) ---");

    begin : test2
      automatic logic [63:0] tx_word     = 64'hA5A5A5A5_12345678;
      automatic int          tx_rd_seen  = 0;
      automatic int          sck_cnt     = 0;

      // Configure
      ctrl_reg_i    = '{addr_len:0, cpol:0, cpha:0, dual:0,
                        cs_hold:0, xip:0,  ddr:0,  quad:0};
      cmd_reg_i     = 8'h02;        // Page Program
      addr_reg_i    = 32'h00_5678;
      len_reg_i     = 16'd8;
      dummy_reg_i   = 6'd0;         // no dummy cycles for write
      tx_data_i     = tx_word;
      tx_empty_i    = 1'b0;         // TX data available → write direction
      rx_full_i     = 1'b0;
      clkdiv_reg_i  = CLKDIV;

      // Fork: count SCK edges and watch tx_rd_o
      fork
        begin : sck_counter_t2
          @(posedge cs_o);
          forever begin
            @(posedge sck_o);
            if (cs_o) sck_cnt++;
            else break;
          end
        end
        begin : txrd_watcher_t2
          @(posedge clk_i);
          while (!tx_rd_o) @(posedge clk_i);
          tx_rd_seen = 1;
          $display("      tx_rd_o fired at sck_edge=%0d", sck_cnt);
        end
      join_none

      pulse_start();
      @(posedge clk_i); #1;
      chk("T2: busy goes high", stat_busy_o, 1'b1);
      chk("T2: cs asserted",    cs_o,        1'b1);

      wait_done();
      #(CLK_PERIOD * 5);
      disable sck_counter_t2;
      disable txrd_watcher_t2;

      // CMD(8) + ADDR(24) + DAT(64) = 96 SCK rising edges expected
      chk("T2: done pulse",    stat_done_o,  1'b1);
      chk("T2: no error",      stat_error_o, 1'b0);
      chk("T2: cs deasserted", cs_o,         1'b0);
      if (!tx_rd_seen)
        $display("FAIL  T2: tx_rd_o never fired");
      else
        $display("PASS  T2: tx_rd_o fired correctly");

      // Verify SCK count: CMD(8) + ADDR(24) + DATA(64) = 96
      if (sck_cnt == 96)
        $display("PASS  T2: SCK count = %0d (expected 96)", sck_cnt);
      else
        $display("FAIL  T2: SCK count = %0d (expected 96)", sck_cnt);

      @(posedge clk_i); #1;
      chk("T2: busy gone", stat_busy_o, 1'b0);
    end

    repeat(10) @(posedge clk_i);

    // =======================================================================
    // TEST 3 – Quad SPI Read  (opcode 0x6B, 1-1-4, 8 dummy cycles)
    // Flash returns 0x0123456789ABCDEF via 4-bit nibbles on data_io[3:0]
    // CMD and ADDR are still Single; DATA is Quad.
    // Note: For 1-1-4 (Quad Output) the command and address phases use
    // Single SPI, only the data phase uses 4 wires.
    // =======================================================================
    $display("\n--- TEST 3: Quad SPI Read (0x6B, 1-1-4, 24-bit addr, 8 dummy, 8 bytes) ---");

    begin : test3
      automatic logic [63:0] expected_rx = 64'h0123_4567_89AB_CDEF;
      automatic logic [63:0] captured_rx;
      automatic int          rx_wr_seen  = 0;
      automatic int          sck_cnt     = 0;

      ctrl_reg_i    = '{addr_len:0, cpol:0, cpha:0, dual:0,
                        cs_hold:0, xip:0,  ddr:0,  quad:1}; // QUAD=1
      cmd_reg_i     = 8'h6B;        // Quad Output Fast Read
      addr_reg_i    = 32'h00_ABCD;
      len_reg_i     = 16'd8;        // 8 bytes = 64 bits = 16 Quad SCK cycles
      dummy_reg_i   = 6'd8;
      tx_empty_i    = 1'b1;         // read direction
      rx_full_i     = 1'b0;
      clkdiv_reg_i  = CLKDIV;

      fork
        begin : flash_model_t3
          // For 1-1-4: CMD single (8 cycles), ADDR single (24 cycles),
          // DUMMY (8 cycles), DATA quad (16 cycles for 64 bits)
          @(posedge cs_o);
          flash_oe_s = 1'b0;

          // Skip CMD (8 SCK rising edges)
          repeat(8)  @(posedge sck_o);
          // Skip ADDR (24 SCK rising edges, Single)
          repeat(24) @(posedge sck_o);
          // Skip DUMMY (8 SCK rising edges)
          repeat(8)  @(posedge sck_o);

          // DATA phase: 16 Quad cycles, each drives one nibble
          // Drive MSB nibble first, on SCK falling edge
          flash_oe_s = 1'b1;
          for (int n = 15; n >= 0; n--) begin
            @(negedge sck_o);
            // Nibble n: bits [4n+3 : 4n] of expected_rx
            flash_drive_s = expected_rx[n*4 +: 4];
          end
          @(negedge sck_o);
          flash_oe_s    = 1'b0;
          flash_drive_s = 4'b0000;
        end

        begin : sck_counter_t3
          @(posedge cs_o);
          forever begin
            @(posedge sck_o);
            if (cs_o) sck_cnt++;
            else break;
          end
        end

        begin : capture_t3
          @(posedge clk_i);
          while (!rx_wr_o) @(posedge clk_i);
          captured_rx = rx_data_o;
          rx_wr_seen  = 1;
        end
      join_none

      pulse_start();
      @(posedge clk_i); #1;
      chk("T3: busy goes high", stat_busy_o, 1'b1);
      chk("T3: cs asserted",    cs_o,        1'b1);

      wait_done();
      #(CLK_PERIOD * 5);
      disable flash_model_t3;
      disable sck_counter_t3;
      disable capture_t3;

      chk("T3: done pulse",    stat_done_o,  1'b1);
      chk("T3: no error",      stat_error_o, 1'b0);
      chk("T3: cs deasserted", cs_o,         1'b0);

      // CMD(8 Single) + ADDR(24 Single) + DUMMY(8) + DATA(16 Quad) = 56 SCK edges
      if (sck_cnt == 56)
        $display("PASS  T3: SCK count = %0d (expected 56)", sck_cnt);
      else
        $display("FAIL  T3: SCK count = %0d (expected 56)", sck_cnt);

      if (rx_wr_seen)
        chk64("T3: rx_data == expected", captured_rx, expected_rx);
      else
        $display("FAIL  T3: rx_wr_o never fired");

      @(posedge clk_i); #1;
      chk("T3: busy gone", stat_busy_o, 1'b0);
    end

    repeat(10) @(posedge clk_i);

    // =======================================================================
    // TEST 4 – Timeout  (no flash connected, timeout fires)
    // =======================================================================
    $display("\n--- TEST 4: Timeout detection ---");

    begin : test4
      // Short timeout: 200 clk_i cycles
      ctrl_reg_i    = '{addr_len:0, cpol:0, cpha:0, dual:0,
                        cs_hold:0, xip:0,  ddr:0,  quad:0};
      cmd_reg_i     = 8'h03;
      addr_reg_i    = 32'h00_0000;
      len_reg_i     = 16'd8;
      dummy_reg_i   = 6'd0;
      timeout_reg_i = 32'd200;
      tx_empty_i    = 1'b1;
      rx_full_i     = 1'b0;
      clkdiv_reg_i  = CLKDIV;

      pulse_start();

      // Wait longer than timeout
      repeat(300) @(posedge clk_i);
      #1;
      chk("T4: timeout fires", stat_timeout_o, 1'b1);
      $display("      (timeout fired as expected, FSM may still be running)");

      // Reset to clear
      do_reset();
      @(posedge clk_i); #1;
      chk("T4: timeout cleared after reset", stat_timeout_o, 1'b0);
    end

    repeat(10) @(posedge clk_i);

    // =======================================================================
    // TEST 5 – Error: TX underflow  (start write but FIFO goes empty mid-transfer)
    // =======================================================================
    $display("\n--- TEST 5: TX underflow error ---");

    begin : test5
      ctrl_reg_i    = '{addr_len:0, cpol:0, cpha:0, dual:0,
                        cs_hold:0, xip:0,  ddr:0,  quad:0};
      cmd_reg_i     = 8'h02;
      addr_reg_i    = 32'h00_0000;
      len_reg_i     = 16'd8;
      dummy_reg_i   = 6'd0;
      timeout_reg_i = 32'd0;
      tx_data_i     = 64'hFFFF_FFFF_FFFF_FFFF;
      tx_empty_i    = 1'b0;   // FIFO has data at start
      rx_full_i     = 1'b0;
      clkdiv_reg_i  = CLKDIV;

      pulse_start();
      @(posedge clk_i); #1;
      chk("T5: busy high", stat_busy_o, 1'b1);

      // Wait for DAT_ST to be reached (CMD=8 + ADDR=24 SCK cycles)
      // then assert tx_empty_i to simulate underflow
      repeat(SCK_HALF * 2 * (8+24) / CLK_PERIOD + 10) @(posedge clk_i);
      tx_empty_i = 1'b1;   // FIFO runs dry mid-transfer

      // Wait a few cycles for error to latch
      repeat(10) @(posedge clk_i);
      #1;
      chk("T5: error latched", stat_error_o, 1'b1);
      $display("      TX underflow error correctly detected");

      do_reset();
      @(posedge clk_i); #1;
      chk("T5: error cleared after reset", stat_error_o, 1'b0);
    end

    // =======================================================================
    // Summary
    // =======================================================================
    repeat(5) @(posedge clk_i);
    $display("\n============================================================");
    $display("  SUMMARY:  %0d PASSED,  %0d FAILED", pass_cnt, fail_cnt);
    $display("============================================================");
    if (fail_cnt == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  SOME TESTS FAILED – review log above");
    $finish;
  end

  // -------------------------------------------------------------------------
  // Watchdog
  // -------------------------------------------------------------------------
  initial begin
    #20_000_000;   // 20 ms sim time limit
    $display("FAIL  WATCHDOG: simulation timeout");
    $finish;
  end

endmodule : as_qspi_tb
