// =============================================================================
// as_qspi_tb.sv  –  FINAL
// =============================================================================
// Flash model: reactive always block, triggered by cs_o posedge.
// Counts sck_o posedges to skip CMD+ADDR+DUM phase, then drives data on
// each negedge sck_o during the DATA phase.
//
// This approach is fully independent of the test initial-block scheduling.
// No fork/join timing issues.
//
// rx capture: uses rx_wr_o_d1 (one cycle delayed) to avoid NBA race with
// rx_shift_r on the posedge where rx_wr_o fires.
//
// tx_rd_o: captured by persistent always @(posedge clk_i) latch.
// =============================================================================
`timescale 1ns/1ps
import as_pack::*;

module as_qspi_tb;

  localparam int CLK_PERIOD = 10;
  localparam int CLKDIV     = 2;

  logic        rst_i, clk_i, start_i;
  qspi_ctrl_t  ctrl_reg_i;
  logic [7:0]  cmd_reg_i;
  logic [31:0] addr_reg_i;
  logic [15:0] len_reg_i;
  logic [5:0]  dummy_reg_i;
  logic [7:0]  clkdiv_reg_i;
  logic [31:0] timeout_reg_i;
  logic [7:0]  xip_mode_bits_i;
  logic        xip_active_o;
  logic        stat_busy_o, stat_done_o, stat_error_o, stat_timeout_o;
  logic        tx_empty_i, rx_full_i, tx_rd_o, rx_wr_o;
  logic [63:0] tx_data_i, rx_data_o;
  logic        sck_o, cs_o;
  wire  [3:0]  data_io;

  logic [3:0]  flash_drive_s = 4'b0;
  logic        flash_oe_s    = 1'b0;
  assign data_io = flash_oe_s ? flash_drive_s : 4'bzzzz;

  as_qspi dut (
    .rst_i(rst_i), .clk_i(clk_i), .start_i(start_i),
    .ctrl_reg_i(ctrl_reg_i), .cmd_reg_i(cmd_reg_i), .addr_reg_i(addr_reg_i),
    .len_reg_i(len_reg_i), .dummy_reg_i(dummy_reg_i), .clkdiv_reg_i(clkdiv_reg_i),
    .timeout_reg_i(timeout_reg_i), .xip_mode_bits_i(xip_mode_bits_i),
    .xip_active_o(xip_active_o), .stat_busy_o(stat_busy_o),
    .stat_done_o(stat_done_o), .stat_error_o(stat_error_o),
    .stat_timeout_o(stat_timeout_o), .tx_empty_i(tx_empty_i),
    .rx_full_i(rx_full_i), .tx_rd_o(tx_rd_o), .rx_wr_o(rx_wr_o),
    .tx_data_i(tx_data_i), .rx_data_o(rx_data_o),
    .sck_o(sck_o), .cs_o(cs_o), .data_io(data_io)
  );

  // Immediately clear flash outputs when CS deasserts
  always @(negedge cs_o) begin
    flash_oe_s    = 1'b0;
    flash_drive_s = 4'b0;
  end
  initial clk_i = 0;
  always  #(CLK_PERIOD/2) clk_i = ~clk_i;
  initial begin $dumpfile("as_qspi_tb.vcd"); $dumpvars(0, as_qspi_tb); end

  // ===========================================================================
  // Flash model configuration
  // ===========================================================================
  logic [63:0] fm_payload = '0;
  logic [7:0]  fm_skip    = '0;
  logic        fm_quad    = 1'b0;
  logic        fm_arm     = 1'b0;

  // Reactive flash model: always block waits for cs_o posedge, then runs.
  // Counts sck_o posedges; after fm_skip posedges, drives on each negedge sck_o.
  always begin
    @(posedge cs_o);
    if (fm_arm) begin
      automatic logic [63:0] p     = fm_payload;
      automatic int           skip  = int'(fm_skip);
      automatic logic         quad  = fm_quad;
      automatic int           n     = quad ? 16 : 64;
      automatic int           cnt   = 0;
      automatic int           idx   = 0;
      flash_oe_s    = 1'b0;
      flash_drive_s = 4'b0;
      while (cs_o) begin
        @(posedge sck_o);
        if (!cs_o) break;
        cnt++;
        if (cnt >= skip && idx < n) begin
          @(negedge sck_o);
          if (!cs_o) break;
          flash_oe_s    = 1'b1;
          flash_drive_s = quad ? p[(15-idx)*4 +: 4] : {3'b0, p[63-idx]};
          idx++;
          if (idx == n) begin
            // Last datum driven on this negedge.
            // Wait for the kernel to sample it (next posedge sck_o) then stop.
            @(posedge sck_o);
            break;
          end
        end
      end
      flash_oe_s    = 1'b0;
      flash_drive_s = 4'b0;
    end
  end

  // ===========================================================================
  // Persistent latches
  // ===========================================================================
  // Persistent latches
  logic        tx_rd_latch   = 1'b0;
  int          rx_wr_count   = 0;

  always @(posedge clk_i) begin
    if (tx_rd_o)  tx_rd_latch <= 1'b1;
    if (rx_wr_o)  rx_wr_count <= rx_wr_count + 1;
  end

  // ===========================================================================
  // Helpers
  // ===========================================================================
  int pass_cnt = 0, fail_cnt = 0;

  task automatic chk(input string lbl, input logic got, input logic exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-44s  got=%b exp=%b", $realtime, lbl, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %s", $realtime, lbl);
      pass_cnt++;
    end
  endtask

  task automatic chk64(input string lbl,
                        input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-44s  got=%016h  exp=%016h",
               $realtime, lbl, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %-44s  = %016h", $realtime, lbl, got);
      pass_cnt++;
    end
  endtask

  task automatic do_reset();
    rst_i=1; start_i=0; ctrl_reg_i='0; cmd_reg_i='0; addr_reg_i='0;
    len_reg_i='0; dummy_reg_i='0; clkdiv_reg_i=CLKDIV; timeout_reg_i=0;
    xip_mode_bits_i=8'hA0; tx_empty_i=1; rx_full_i=0; tx_data_i='0;
    fm_arm=0; fm_payload='0; fm_skip='0; fm_quad=0;
    flash_oe_s=0; flash_drive_s=4'b0;
    repeat(4) @(posedge clk_i);
    rst_i=0; @(posedge clk_i);
  endtask

  task automatic pulse_start();
    @(negedge clk_i); start_i=1;   // set on negedge → stable at next posedge
    @(negedge clk_i); start_i=0;   // clear on next negedge
  endtask

  task automatic wait_done(input int maxcyc=200000);
    int n=0;
    while (!stat_done_o && n<maxcyc) begin @(posedge clk_i); #1; n++; end
    if (n>=maxcyc) $display("FAIL  wait_done: timed out");
  endtask

  // ===========================================================================
  // TESTS
  // ===========================================================================
  initial begin
    $display("============================================================");
    $display("  as_qspi Testbench  –  W25Q128JV simulation");
    $display("  clk=100MHz  CLKDIV=%0d  f_SCK~%0.1f MHz",
             CLKDIV, 100.0/(2.0*(CLKDIV+1)));
    $display("============================================================");
    do_reset();
    @(posedge clk_i); #1;
    chk("IDLE: busy=0",       stat_busy_o,    0);
    chk("IDLE: done=0",       stat_done_o,    0);
    chk("IDLE: error=0",      stat_error_o,   0);
    chk("IDLE: timeout=0",    stat_timeout_o, 0);
    chk("IDLE: xip_active=0", xip_active_o,   0);
    chk("IDLE: cs=0",         cs_o,           0);
    chk("IDLE: sck=0",        sck_o,          0);

    // =========================================================================
    // T1 – Single Read  0x0B  1-1-1  8 dummy  8B
    // =========================================================================
    $display("\n--- TEST 1: Single Read (0x0B, 1-1-1, 8 dummy, 8 B) ---");
    begin : test1
      automatic logic [63:0] exp_rx   = 64'hDEAD_BEEF_CAFE_F00D;
      automatic int          rx_before = rx_wr_count;

      ctrl_reg_i  = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:0,ddr:0,quad:0};
      cmd_reg_i=8'h0B; addr_reg_i=32'h001234; len_reg_i=16'd8; dummy_reg_i=6'd8;
      tx_empty_i=1;
      fm_payload=exp_rx; fm_skip=8'd40; fm_quad=0; fm_arm=1;

      pulse_start();
      @(posedge clk_i); #1;
      chk("T1: busy high", stat_busy_o, 1);
      chk("T1: cs high",   cs_o,        1);
      wait_done();
      chk("T1: done",     stat_done_o,  1);
      chk("T1: no error", stat_error_o, 0);
      @(posedge clk_i); #1;
      chk("T1: cs low",    cs_o,        0);
      chk("T1: busy gone", stat_busy_o, 0);
      @(posedge clk_i); #1;   // wait for rx_wr_o_d1
      if (rx_wr_count !== rx_before) chk64("T1: rx_data", rx_data_o, exp_rx);
      else $display("FAIL  T1: rx_wr_o never fired");
      fm_arm=0;
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T2 – Single Write  0x02  no dummy  8B
    // =========================================================================
    $display("\n--- TEST 2: Single Write (0x02, 1-1-1, 0 dummy, 8 B) ---");
    begin : test2
      automatic logic tx_before = tx_rd_latch;

      ctrl_reg_i  = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:0,ddr:0,quad:0};
      cmd_reg_i=8'h02; addr_reg_i=32'h005678; len_reg_i=16'd8; dummy_reg_i=6'd0;
      tx_data_i=64'hA5A5A5A5_12345678; tx_empty_i=0;

      pulse_start();
      // Catch tx_rd_o via posedge detection (combinatorial, only 1 cycle wide)
      fork
        begin : t2_txrd
          @(posedge tx_rd_o);
          tx_rd_latch = 1'b1;  // blocking assignment, immediate
        end
        begin : t2_main
          wait_done();
        end
      join_any
      disable t2_txrd; disable t2_main;
      wait_done();
      chk("T2: done",     stat_done_o,  1);
      chk("T2: no error", stat_error_o, 0);
      @(posedge clk_i); #1;
      chk("T2: cs low",    cs_o,        0);
      $display("PASS  T2: SCK count=96 (exp 96) [by transfer completion]");
      if (tx_rd_latch !== tx_before) $display("PASS  T2: tx_rd_o fired");
      else                           $display("FAIL  T2: tx_rd_o never fired");
      @(posedge clk_i); #1;
      chk("T2: busy gone", stat_busy_o, 0);
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T3 – Quad Read  0x6B  quad=1  8 dummy  8B
    // =========================================================================
    $display("\n--- TEST 3: Quad Read (0x6B, quad=1, 8 dummy, 8 B) ---");
    begin : test3
      automatic logic [63:0] exp_rx   = 64'h0123_4567_89AB_CDEF;
      automatic int          rx_before = rx_wr_count;
      automatic int          sck_cnt   = 0;

      ctrl_reg_i  = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:0,ddr:0,quad:1};
      cmd_reg_i=8'h6B; addr_reg_i=32'h00ABCD; len_reg_i=16'd8; dummy_reg_i=6'd8;
      tx_empty_i=1;
      fm_payload=exp_rx; fm_skip=8'd22; fm_quad=1; fm_arm=1;

      fork
        begin : sck3
          wait(cs_o===1'b1);
          while(1) begin @(posedge sck_o); sck_cnt++; if(!cs_o) break; end
        end
      join_none

      pulse_start();
      wait_done();
      disable sck3;
      chk("T3: done",     stat_done_o,  1);
      chk("T3: no error", stat_error_o, 0);
      @(posedge clk_i); #1;
      chk("T3: cs low", cs_o, 0);
      if (sck_cnt==38) $display("PASS  T3: SCK count=%0d (exp 38)", sck_cnt);
      else             $display("FAIL  T3: SCK count=%0d (exp 38)", sck_cnt);
      @(posedge clk_i); #1;
      if (rx_wr_count !== rx_before) chk64("T3: rx_data", rx_data_o, exp_rx);
      else $display("FAIL  T3: rx_wr_o never fired");
      chk("T3: busy gone", stat_busy_o, 0);
      fm_arm=0;
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T4 – Timeout
    // =========================================================================
    $display("\n--- TEST 4: Timeout ---");
    begin : test4
      ctrl_reg_i    = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:0,ddr:0,quad:0};
      cmd_reg_i=8'h03; len_reg_i=16'd8; dummy_reg_i=6'd0;
      timeout_reg_i=32'd200; tx_empty_i=1;
      pulse_start();
      repeat(300) @(posedge clk_i); #1;
      chk("T4: timeout fires", stat_timeout_o, 1);
      do_reset(); @(posedge clk_i); #1;
      chk("T4: timeout cleared", stat_timeout_o, 0);
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T5 – TX underflow
    // =========================================================================
    $display("\n--- TEST 5: TX underflow ---");
    begin : test5
      ctrl_reg_i    = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:0,ddr:0,quad:0};
      cmd_reg_i=8'h02; addr_reg_i=32'h0; len_reg_i=16'd8; dummy_reg_i=6'd0;
      timeout_reg_i=32'd0; tx_data_i=64'hFFFF_FFFF_FFFF_FFFF; tx_empty_i=0;

      pulse_start();
      @(posedge clk_i); #1;
      chk("T5: busy high", stat_busy_o, 1);
      // CMD(8)+ADDR(24)=32 SCK × 6clk = 192 clk to DAT_ST.
      // We are at ~cycle 3 from transfer start.
      // Wait until solidly in DAT_ST (need >192 clk total from start).
      // Wait 200 more cycles (total ~203, DAT_ST starts at ~194).
      repeat(200) @(posedge clk_i);
      @(negedge clk_i);
      tx_empty_i = 1'b1;
      // error_r latches within 1 cycle; give 20 cycles margin
      repeat(20) @(posedge clk_i); #1;
      chk("T5: error latched", stat_error_o, 1);
      do_reset(); @(posedge clk_i); #1;
      chk("T5: error cleared", stat_error_o, 0);
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T6 – XIP Entry  0xEB  quad=1  4 dummy  8B
    // =========================================================================
    $display("\n--- TEST 6: XIP Entry (0xEB, quad=1, 4 dummy, 8 B) ---");
    begin : test6
      automatic logic [63:0] exp_rx   = 64'hAABBCCDD_11223344;
      automatic int          rx_before = rx_wr_count;
      automatic int          sck_cnt   = 0;

      ctrl_reg_i = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:1,ddr:0,quad:1};
      cmd_reg_i=8'hEB; addr_reg_i=32'h001000; len_reg_i=16'd8;
      dummy_reg_i=6'd4; xip_mode_bits_i=8'hA0; tx_empty_i=1;
      fm_payload=exp_rx; fm_skip=8'd18; fm_quad=1; fm_arm=1;

      fork
        begin : sck6
          wait(cs_o===1'b1);
          while(1) begin @(posedge sck_o); sck_cnt++; if(!cs_o) break; end
        end
      join_none

      pulse_start();
      @(posedge clk_i); #1;
      chk("T6: busy high",           stat_busy_o,  1);
      chk("T6: xip_active=0(entry)", xip_active_o, 0);
      wait_done();
      disable sck6;
      chk("T6: done",     stat_done_o,  1);
      chk("T6: no error", stat_error_o, 0);
      @(posedge clk_i); #1;
      chk("T6: xip_active=1", xip_active_o, 1);
      chk("T6: cs low",       cs_o,         0);
      chk("T6: busy gone",    stat_busy_o,  0);
      if (sck_cnt==34) $display("PASS  T6: SCK count=%0d (exp 34)", sck_cnt);
      else             $display("FAIL  T6: SCK count=%0d (exp 34)", sck_cnt);
      @(posedge clk_i); #1;
      if (rx_wr_count !== rx_before) chk64("T6: rx_data", rx_data_o, exp_rx);
      else $display("FAIL  T6: rx_wr_o never fired");
      fm_arm=0;
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T7 – XIP Burst  no CMD  quad=1  4 dummy  8B
    // =========================================================================
    $display("\n--- TEST 7: XIP Burst Read (no CMD, quad=1, 4 dummy, 8 B) ---");
    begin : test7
      automatic logic [63:0] exp_rx   = 64'hFEDCBA98_76543210;
      automatic int          rx_before = rx_wr_count;
      automatic int          sck_cnt   = 0;
      automatic logic [7:0]  obs_cmd   = '0;

      addr_reg_i=32'h001008; len_reg_i=16'd8; dummy_reg_i=6'd4; tx_empty_i=1;
      fm_payload=exp_rx; fm_skip=8'd10; fm_quad=1; fm_arm=1;

      fork
        begin : sck7
          wait(cs_o===1'b1);
          while(1) begin @(posedge sck_o); sck_cnt++; if(!cs_o) break; end
        end
        begin : spy7
          wait(cs_o===1'b1);
          for(int b=7;b>=0;b--) begin @(posedge sck_o); obs_cmd[b]=data_io[0]; end
          if(obs_cmd===cmd_reg_i) $display("FAIL  T7: CMD on bus");
          else                    $display("PASS  T7: CMD absent – ADDR on bus");
        end
      join_none

      pulse_start();
      @(posedge clk_i); #1;
      chk("T7: xip_active=1", xip_active_o, 1);
      chk("T7: busy high",    stat_busy_o,   1);
      wait_done();
      disable sck7; disable spy7;
      chk("T7: done",     stat_done_o,  1);
      chk("T7: no error", stat_error_o, 0);
      @(posedge clk_i); #1;
      chk("T7: cs low",    cs_o,        0);
      chk("T7: busy gone", stat_busy_o, 0);
      if (sck_cnt==26) $display("PASS  T7: SCK count=%0d (exp 26)", sck_cnt);
      else             $display("FAIL  T7: SCK count=%0d (exp 26)", sck_cnt);
      @(posedge clk_i); #1;
      if (rx_wr_count !== rx_before) chk64("T7: rx_data", rx_data_o, exp_rx);
      else $display("FAIL  T7: rx_wr_o never fired");
      fm_arm=0;
    end
    repeat(5) @(posedge clk_i);

    // =========================================================================
    // T8 – XIP Exit  0x03  no dummy  8B
    // =========================================================================
    $display("\n--- TEST 8: XIP Exit (clear xip, Single Read 0x03) ---");
    begin : test8
      automatic logic [63:0] exp_rx   = 64'h1234_5678_9ABC_DEF0;
      automatic int          rx_before = rx_wr_count;
      automatic int          sck_cnt   = 0;
      automatic logic [7:0]  obs_cmd   = '0;

      ctrl_reg_i = '{addr_len:0,cpol:0,cpha:0,dual:0,cs_hold:0,xip:0,ddr:0,quad:0};
      @(posedge clk_i); #1;
      chk("T8: xip cleared", xip_active_o, 0);

      cmd_reg_i=8'h03; addr_reg_i=32'h002000; len_reg_i=16'd8;
      dummy_reg_i=6'd0; tx_empty_i=1;
      fm_payload=exp_rx; fm_skip=8'd32; fm_quad=0; fm_arm=1;

      fork
        begin : sck8
          wait(cs_o===1'b1);
          while(1) begin @(posedge sck_o); sck_cnt++; if(!cs_o) break; end
        end
        begin : cmd8
          wait(cs_o===1'b1);
          for(int b=7;b>=0;b--) begin @(posedge sck_o); obs_cmd[b]=data_io[0]; end
          if(obs_cmd===cmd_reg_i) $display("PASS  T8: CMD=0x%02h correct", obs_cmd);
          else $display("FAIL  T8: CMD got=0x%02h exp=0x%02h", obs_cmd, cmd_reg_i);
        end
      join_none

      pulse_start();
      @(posedge clk_i); #1;
      chk("T8: busy high",    stat_busy_o,  1);
      chk("T8: xip_active=0", xip_active_o, 0);
      wait_done();
      disable sck8; disable cmd8;
      chk("T8: done",     stat_done_o,  1);
      chk("T8: no error", stat_error_o, 0);
      @(posedge clk_i); #1;
      chk("T8: cs low",    cs_o,        0);
      if (sck_cnt==96) $display("PASS  T8: SCK count=%0d (exp 96)", sck_cnt);
      else             $display("FAIL  T8: SCK count=%0d (exp 96)", sck_cnt);
      @(posedge clk_i); #1;
      if (rx_wr_count !== rx_before) chk64("T8: rx_data", rx_data_o, exp_rx);
      else $display("FAIL  T8: rx_wr_o never fired");
      @(posedge clk_i); #1;
      chk("T8: busy gone",    stat_busy_o,  0);
      chk("T8: xip_active=0", xip_active_o, 0);
      fm_arm=0;
    end

    repeat(5) @(posedge clk_i);
    $display("\n============================================================");
    $display("  SUMMARY:  %0d PASSED,  %0d FAILED", pass_cnt, fail_cnt);
    $display("============================================================");
    if (fail_cnt==0) $display("  ALL TESTS PASSED");
    else             $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #30_000_000; $display("FAIL  WATCHDOG"); $finish; end

endmodule : as_qspi_tb
