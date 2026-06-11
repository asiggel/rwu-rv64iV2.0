`timescale 1ns/1ps

import as_pack::*;

// Unified instruction testbench for RV_NoPipelineCache.
// Configured via plusargs:
//   +TEST_NAME=<name>     log label written to error.txt
//   +EXPECTED=<int>       GPIO byte value that signals test success
module tb_rv64i ();
  parameter tclk_2_t = 20;
  parameter clk_2_t  = 5;
  parameter clk_80_t = 400;

  logic clk_s, clk_core_s, clk_div_s;
  logic rst_s;
  logic tck_s, trst_s, tms_s, tdi_s, tdo_s;
  tri [nr_gpios-1:0] gpio_s;
  logic              cs_s;
  int    fd;
  string test_name;
  int    expected;
  int    cs_count;

  // Flash memory: instructions loaded from riscvtest.mem (32-bit words)
  localparam int FLASH_WORDS = 16384;
  logic [31:0] flash_mem_s [0:FLASH_WORDS-1];
  initial $readmemh("riscvtest.mem", flash_mem_s);

  logic       sck_s;
  logic       flash_cs_s;
  wire  [3:0] flash_data_s;
  logic [3:0] flash_drive_s = 4'b0;
  logic       flash_oe_s    = 1'b0;
  assign flash_data_s = flash_oe_s ? flash_drive_s : 4'bzzzz;

  as_top_mem DUT (
    .clk_i(clk_s), .rst_i(rst_s),
    .tck_i(tck_s), .trst_i(trst_s), .tms_i(tms_s), .tdi_i(tdi_s), .tdo_o(tdo_s),
    .gpio_io(gpio_s),
    .cs_o(cs_s),
    .sck_o(sck_s),
    .flash_cs_o(flash_cs_s),
    .flash_data_io(flash_data_s),
    .clk_div_o(clk_div_s),
    .uart0_tx_o(),
    .uart0_rx_i(1'b1)
  );

  initial begin rst_s <= 1; #(10*2*clk_2_t); rst_s <= 0; end

  initial begin
    fd = $fopen("./error.txt", "a");
    if (!$value$plusargs("TEST_NAME=%s", test_name)) test_name = "unknown";
    if (!$value$plusargs("EXPECTED=%0d", expected))  expected  = -1;
    cs_count = 0;
  end

  always begin clk_s     <= 1; #clk_2_t;  clk_s     <= 0; #clk_2_t;  end
  always begin clk_core_s <= 1; #clk_80_t; clk_core_s <= 0; #clk_80_t; end

  initial begin tck_s <= 0; tms_s <= 0; tdi_s <= 0; trst_s <= 0; end

  initial begin #2000000000; $display("WATCHDOG: 2ms timeout"); $finish; end

  //------------------------------------------
  // QSPI NOR flash model (W25Q-style, Quad Output Fast Read 0x6B)
  //------------------------------------------
  task automatic flash_transaction();
    logic [23:0] faddr = '0;
    logic [63:0] fword = '0;
    int          widx  = 0;
    int          cnt   = 0;
    int          idx   = 0;
    flash_oe_s    = 1'b0;
    flash_drive_s = 4'b0;
    while (flash_cs_s) begin
      @(posedge sck_s); if (!flash_cs_s) return;
      cnt++;
      if (cnt >= 9 && cnt <= 14)
        faddr = {faddr[19:0], flash_data_s[3:0]};
      if (cnt >= 22 && idx < 16) begin
        @(negedge sck_s); if (!flash_cs_s) return;
        if (idx == 0) begin
          widx  = int'(faddr) >> 2;
          fword = {flash_mem_s[widx+1], flash_mem_s[widx]};
        end
        flash_oe_s    = 1'b1;
        flash_drive_s = fword[63:60];
        fword         = {fword[59:0], 4'b0};
        idx++;
        if (idx == 16) begin @(posedge sck_s); return; end
      end
    end
  endtask

  always @(negedge flash_cs_s) begin flash_oe_s = 1'b0; flash_drive_s = 4'b0; end
  always begin
    @(posedge flash_cs_s);
    flash_transaction();
    flash_oe_s    = 1'b0;
    flash_drive_s = 4'b0;
  end

  //------------------------------------------
  // Check results on every cs_o rising edge
  //------------------------------------------
  always @(posedge cs_s) begin
    #1;  // let gpio_io settle (same NBA region as cs_o)
    cs_count++;
    $display("CS #%0d: gpio=0x%0h  expected=0x%0h", cs_count, gpio_s, expected);
    if (gpio_s == expected) begin
      $display("Simulation %s succeeded", test_name);
      #100; #(1*2*clk_2_t);
      $fdisplay(fd, "%s - %s: Test ok", get_time(), test_name);
      $fclose(fd); $stop;
    end else if (cs_count >= 20) begin
      $fdisplay(fd, "%s - %s: Test fail", get_time(), test_name);
      $fclose(fd); $stop;
    end
  end

  function string get_time();
    int file_pointer;
    void'($system("date +%x > sys_time"));
    file_pointer = $fopen("sys_time", "r");
    void'($fscanf(file_pointer, "%s", get_time));
    $fclose(file_pointer);
    void'($system("rm sys_time"));
  endfunction

endmodule : tb_rv64i
