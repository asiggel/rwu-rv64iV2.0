// tb_rv64i_uart_tx.sv — RV_NoPipeline system-level UART TX test
// Firmware sends "Hello Rocker" over UART0; TB decodes the serial stream and verifies.
// Pass: all 12 bytes match expected ASCII.
`timescale 1ns/1ps

import as_pack::*;

module tb_rv64i ();
  parameter int clk_2_t  = 5;    // system clock half-period [ns] → 100 MHz
  parameter int clk_80_t = 400;  // monitoring-clock half-period [ns]

  // Core clock: CGU divides system clock by 80 → period = 800 ns
  // UART BIT_PERIOD = 16 × CLKDIV × core_clk_period; firmware sets CLKDIV = 4
  localparam int BIT_PERIOD = 16 * 4 * (2 * clk_80_t);  // 51200 ns

  logic clk_s, clk_core_s;
  logic rst_s;
  logic tck_s, trst_s, tms_s, tdi_s, tdo_s;
  tri [nr_gpios-1:0] gpio_s;
  logic cs_s;
  logic uart0_tx_s;

  logic [7:0]  expected [0:11];
  logic [7:0]  got;
  logic        ferr;
  int          fail_cnt;
  int          i;
  int          fd;

  logic [instr_width-1:0] iram_s[imemdepth-1:0];

  as_top_mem DUT (
    .clk_i(clk_s), .rst_i(rst_s),
    .tck_i(tck_s), .trst_i(trst_s), .tms_i(tms_s), .tdi_i(tdi_s), .tdo_o(tdo_s),
    .gpio_io(gpio_s),
    .cs_o(cs_s),
    .uart0_tx_o(uart0_tx_s),
    .uart0_rx_i(1'b1)
  );

  initial $readmemh("riscvtest.mem", iram_s);
  initial begin rst_s <= 1; #(10*2*clk_2_t); rst_s <= 0; end
  initial begin fd = $fopen("./error.txt", "a"); end
  always  begin clk_s    <= 1; #clk_2_t;  clk_s    <= 0; #clk_2_t; end
  always  begin clk_core_s <= 1; #clk_80_t; clk_core_s <= 0; #clk_80_t; end
  initial begin tck_s <= 0; tms_s <= 0; tdi_s <= 0; trst_s <= 0; end

  // Decode one 8N1 frame from uart0_tx_s (self-synchronising on falling start edge)
  task automatic tx_recv_8n1(output logic [7:0] data, output logic frame_err);
    int j;
    @(negedge uart0_tx_s);        // wait for start-bit falling edge
    #(BIT_PERIOD / 2);            // advance to centre of start bit
    frame_err = 1'b0;
    data      = 8'h00;
    for (j = 0; j < 8; j++) begin
      #BIT_PERIOD;                // advance to centre of each data bit
      data[j] = uart0_tx_s;
    end
    #BIT_PERIOD;                  // stop bit
    if (uart0_tx_s !== 1'b1) frame_err = 1'b1;
  endtask

  // Receive "Hello Rocker" from serial TX and compare
  initial begin
    expected[0]  = 8'h48; // H
    expected[1]  = 8'h65; // e
    expected[2]  = 8'h6C; // l
    expected[3]  = 8'h6C; // l
    expected[4]  = 8'h6F; // o
    expected[5]  = 8'h20; // (space)
    expected[6]  = 8'h52; // R
    expected[7]  = 8'h6F; // o
    expected[8]  = 8'h63; // c
    expected[9]  = 8'h6B; // k
    expected[10] = 8'h65; // e
    expected[11] = 8'h72; // r

    fail_cnt = 0;
    for (i = 0; i < 12; i++) begin
      tx_recv_8n1(got, ferr);
      if (ferr || got !== expected[i]) begin
        $display("  FAIL  uart_tx[%0d]: exp=0x%02h got=0x%02h ferr=%b",
                 i, expected[i], got, ferr);
        fail_cnt++;
      end
    end

    if (fail_cnt == 0) begin
      $display("Simulation uart_tx succeeded: \"Hello Rocker\" received correctly");
      $fdisplay(fd, "%s - uart_tx: Test ok", get_time());
    end else begin
      $display("Simulation uart_tx FAILED: %0d byte(s) wrong", fail_cnt);
      $fdisplay(fd, "%s - uart_tx: Test fail", get_time());
    end
    $fclose(fd);
    $stop;
  end

  initial begin
    #50_000_000;
    $display("WATCHDOG: 50 ms timeout — uart_tx");
    $fdisplay(fd, "%s - uart_tx: Test fail (watchdog)", get_time());
    $fclose(fd);
    $finish;
  end

  function string get_time();
    int fp;
    void'($system("date +%x > sys_time"));
    fp = $fopen("sys_time","r");
    void'($fscanf(fp,"%s",get_time));
    $fclose(fp);
    void'($system("rm sys_time"));
  endfunction

endmodule : tb_rv64i
