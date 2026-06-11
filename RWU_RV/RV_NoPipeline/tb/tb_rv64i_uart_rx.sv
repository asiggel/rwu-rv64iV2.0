// tb_rv64i_uart_rx.sv — RV_NoPipeline system-level UART RX test
// TB injects "We will rock you." (17 bytes) via UART0 RX at CLKDIV=4 baud.
// Firmware reads each byte and writes GPIO[7:0]=0x55 on pass, 0xFF on fail.
`timescale 1ns/1ps

import as_pack::*;

module tb_rv64i ();
  parameter int clk_2_t  = 5;    // system clock half-period [ns] → 100 MHz
  parameter int clk_80_t = 400;  // monitoring-clock half-period [ns]

  // Core clock: CGU divides system clock by 80 → period = 800 ns
  // UART BIT_PERIOD = 16 × CLKDIV × core_clk_period; firmware sets CLKDIV = 4
  localparam int BIT_PERIOD    = 16 * 4 * (2 * clk_80_t);  // 51200 ns
  // Wait after reset before injecting: firmware needs ~10 µs to set CLKDIV
  localparam int INJECT_DELAY  = 1_000_000;  // 1 ms — conservative margin

  logic clk_s, clk_core_s;
  logic rst_s;
  logic tck_s, trst_s, tms_s, tdi_s, tdo_s;
  tri [nr_gpios-1:0] gpio_s;
  logic cs_s;
  logic uart0_rx_s = 1'b1;  // UART idle = high

  logic [instr_width-1:0] iram_s[imemdepth-1:0];
  int fd;

  as_top_mem DUT (
    .clk_i(clk_s), .rst_i(rst_s),
    .tck_i(tck_s), .trst_i(trst_s), .tms_i(tms_s), .tdi_i(tdi_s), .tdo_o(tdo_s),
    .gpio_io(gpio_s),
    .cs_o(cs_s),
    .uart0_tx_o(),
    .uart0_rx_i(uart0_rx_s)
  );

  initial $readmemh("riscvtest.mem", iram_s);
  initial begin rst_s <= 1; #(10*2*clk_2_t); rst_s <= 0; end
  initial begin fd = $fopen("./error.txt", "a"); end
  always  begin clk_s    <= 1; #clk_2_t;  clk_s    <= 0; #clk_2_t; end
  always  begin clk_core_s <= 1; #clk_80_t; clk_core_s <= 0; #clk_80_t; end
  initial begin tck_s <= 0; tms_s <= 0; tdi_s <= 0; trst_s <= 0; end

  // ── Inject one 8N1 UART frame onto uart0_rx_s ────────────────────────────
  task automatic rx_send_byte(input logic [7:0] data);
    int i;
    uart0_rx_s = 1'b0; #BIT_PERIOD;       // start bit
    for (i = 0; i < 8; i++) begin
      uart0_rx_s = data[i]; #BIT_PERIOD;  // data bits LSB-first
    end
    uart0_rx_s = 1'b1; #BIT_PERIOD;       // stop bit
  endtask

  // ── Inject "We will rock you." after firmware has set CLKDIV ─────────────
  initial begin
    // Wait until firmware has executed CLKDIV=4 write (a few µs; 1 ms is ample)
    #(10*2*clk_2_t + INJECT_DELAY);

    // "We will rock you." — 17 bytes
    rx_send_byte(8'h57);  // W
    rx_send_byte(8'h65);  // e
    rx_send_byte(8'h20);  // (space)
    rx_send_byte(8'h77);  // w
    rx_send_byte(8'h69);  // i
    rx_send_byte(8'h6C);  // l
    rx_send_byte(8'h6C);  // l
    rx_send_byte(8'h20);  // (space)
    rx_send_byte(8'h72);  // r
    rx_send_byte(8'h6F);  // o
    rx_send_byte(8'h63);  // c
    rx_send_byte(8'h6B);  // k
    rx_send_byte(8'h20);  // (space)
    rx_send_byte(8'h79);  // y
    rx_send_byte(8'h6F);  // o
    rx_send_byte(8'h75);  // u
    rx_send_byte(8'h2E);  // .
  end

  // ── Monitor GPIO: firmware writes 0x55 = pass, 0xFF = fail ───────────────
  always @(negedge clk_core_s)
  begin
    if (cs_s === 1) begin
      $display("CS detected: gpio = 0x%02h", gpio_s);
      case (gpio_s[7:0])
        8'h55 : begin
                  $display("Simulation uart_rx succeeded: firmware verified \"We will rock you.\"");
                  $fdisplay(fd, "%s - uart_rx: Test ok", get_time());
                  $fclose(fd);
                  $stop;
                end
        8'hFF : begin
                  $display("Simulation uart_rx FAILED: firmware reported mismatch");
                  $fdisplay(fd, "%s - uart_rx: Test fail", get_time());
                  $fclose(fd);
                  $stop;
                end
        default: ; // intermediate GPIO writes (none expected in this test)
      endcase
    end
  end

  initial begin
    #100_000_000;
    $display("WATCHDOG: 100 ms timeout — uart_rx");
    $fdisplay(fd, "%s - uart_rx: Test fail (watchdog)", get_time());
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
