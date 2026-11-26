
`timescale 1ns/1ps

import as_pack::*;

// Scan test through the JTAG instruction SCANTEST (IR = 129).
//
// Checks
//   1. Clocking: with SCANTEST loaded the core clock clk_div_s is TCK, enabled
//      only in Capture-DR and Shift-DR: exactly n_shift + 1 rising edges for
//      one scan operation with n_shift shift cycles, none in Run-Test/Idle.
//   2. Chain: a pseudo-random pattern shifted in at TDI comes out at TDO,
//      delayed by the chain length. RTL: length 0 (as_top_mem connects
//      sc01_tdi to sc01_tdo). Gate level: the length Genus reports for the
//      inserted chain, given as +SCAN_LENGTH=<n>.
module tb_rv64i ();
  localparam int tclk_2_t = 500;   // half TCK period, 1 MHz TCK
  localparam int n_pat    = 64;    // pattern bits beyond the chain length

  logic clk_s;
  logic rst_s;
  logic tck_s, trst_s, tms_s, tdi_s, tdo_s;
  tri   [nr_gpios-1:0] gpio_s;
  logic [nr_gpios-1:0] gpio_o_s, gpio_oe_s;
  logic                cs_s;

  int   fd;
  int   scan_length;
  int   n_shift;
  int   delay;
  int   clk_edges;
  int   errors;
  logic pat_s [];
  logic out_s [];

  as_top_mem DUT (.clk_i(clk_s),
                  .rst_i(rst_s),
                  .tck_i(tck_s),
                  .trst_i(trst_s),
                  .tms_i(tms_s),
                  .tdi_i(tdi_s),
                  .tdo_o(tdo_s),
                  .gpio_o(gpio_o_s), .gpio_oe_o(gpio_oe_s), .gpio_i(gpio_s),
                  .cs_o(cs_s),
                  .uart0_tx_o(),
                  .uart0_rx_i(1'b1)
                 );

  // GPIO pins: the tri-state driver is in the pad ring (cc_chip_top)
  genvar gp;
  generate
    for (gp = 0; gp < nr_gpios; gp++)
    begin : g_gpio_pin
      assign gpio_s[gp] = gpio_oe_s[gp] ? gpio_o_s[gp] : 1'bz;
    end
  endgenerate

  // TCK
  always
  begin
    tck_s <= 0; #tclk_2_t; tck_s <= 1; #tclk_2_t;
  end

  // Rising edges of the core clock
  always @(posedge DUT.clk_div_s)
    clk_edges++;

  initial
  begin
    fd     = $fopen("./error.txt", "a");
    errors = 0;
    if (!$value$plusargs("SCAN_LENGTH=%d", scan_length))
      scan_length = 0;
    // TDO is sampled at the rising TCK edge after the falling edge that
    // loads the TDO register. A bit shifted into the first chain flip-flop
    // with rising edge i is therefore sampled with rising edge i+L. With the
    // RTL chain of length 0, TDI reaches the TDO register directly, which
    // takes one cycle as well.
    delay   = (scan_length == 0) ? 1 : scan_length;
    n_shift = delay + n_pat;

    clk_s  = 1'b0;   // clk_i not needed: in SCANTEST the core runs on TCK
    rst_s  = 1'b1;
    trst_s = 1'b1;
    tdi_s  = 1'b0;
    tms_s  = 1'b0;
    #(tclk_2_t/2);
    jtag_sw_rst(tclk_2_t);
    jtag_load_ir(tclk_2_t, 8'h81);   // SCANTEST
    rst_s = 1'b0;                    // scan flip-flops out of reset

    // 1a. no core clock in Run-Test/Idle
    clk_edges = 0;
    repeat (10) @(negedge tck_s);
    check("no core clock in Run-Test/Idle", clk_edges == 0);

    // 1b + 2. one scan operation
    pat_s = new[n_shift];
    out_s = new[n_shift];
    foreach (pat_s[i])
      pat_s[i] = 1'($urandom_range(1, 0));
    clk_edges = 0;
    jtag_scan(tclk_2_t);
    check($sformatf("core clock edges = %0d (expected %0d)", clk_edges, n_shift + 1),
          clk_edges == n_shift + 1);

    for (int i = delay; i < n_shift; i++)
      if (out_s[i] !== pat_s[i - delay])
        errors++;
    check($sformatf("pattern through chain of length %0d (%0d bit errors)",
                    scan_length, errors), errors == 0);

    $fclose(fd);
    $stop;
  end

  task check(string what, bit ok);
  begin
    $display("%s: %s", ok ? "OK  " : "FAIL", what);
    $fdisplay(fd, "%s - scan test, %s: %s", get_time(), what,
              ok ? "Test ok" : "Test fail");
  end
  endtask

//------------------------------------------
// JTAG tasks
//------------------------------------------

  task jtag_sw_rst(int cl_2_t);
  begin
    tms_s = 1; #(5*2*cl_2_t);
  end
  endtask

  task jtag_load_ir(int cl_2_t, logic [7:0] ir);
  begin
    // from reset
    tms_s = 0; #(2*cl_2_t); // Run-Test-Idle
    tms_s = 1; #(2*cl_2_t); // Select-DR-Scan
    tms_s = 1; #(2*cl_2_t); // Select-IR-Scan
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // Capture-IR
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // Shift-IR (dummy: parallel load absorbs this slot)
    for (int i = 7; i > 0; i--)
    begin
      tdi_s = ir[i]; tms_s = 0; #(2*cl_2_t); // Shift-IR
    end
    tdi_s = ir[0]; tms_s = 1; #(2*cl_2_t); // Exit1-IR
    tdi_s = 0; tms_s = 1; #(2*cl_2_t); // Update-IR
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // Run-Test-Idle
  end
  endtask

  // From Run-Test/Idle: Capture-DR, n_shift x Shift-DR, back to Run-Test/Idle.
  // pat_s[i] is applied in the i-th Shift-DR cycle, out_s[i] is TDO sampled at
  // the rising TCK edge that ends it. The TB drives a quarter period before
  // the rising edge.
  task jtag_scan(int cl_2_t);
  begin
    tdi_s = 0; tms_s = 1; #(2*cl_2_t); // -> Select-DR-Scan
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // -> Capture-DR
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // -> Shift-DR
    for (int i = 0; i < n_shift; i++)
    begin
      tdi_s = pat_s[i];
      tms_s = (i == n_shift - 1);       // last bit: -> Exit1-DR
      @(posedge tck_s);
      out_s[i] = tdo_s;
      #(cl_2_t + cl_2_t/2);              // to the next drive point
    end
    tdi_s = 0; tms_s = 1; #(2*cl_2_t); // -> Update-DR
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // -> Run-Test-Idle
  end
  endtask

  function string get_time();
    int file_pointer;
    void'($system("date +%x > sys_time"));
    file_pointer = $fopen("sys_time","r");
    void'($fscanf(file_pointer,"%s",get_time));
    $fclose(file_pointer);
    void'($system("rm sys_time"));
  endfunction

endmodule : tb_rv64i
