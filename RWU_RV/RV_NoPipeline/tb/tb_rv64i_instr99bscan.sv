
`timescale 1ns/1ps

import as_pack::*;

// Boundary-scan test (cc_bscan, IEEE 1149.1 instructions).
//
// The program (instr99bscan.asm) sets GPIO 3..0 as outputs = 0101 and
// GPIO 7..4 as inputs; the testbench drives GPIO 7..4 and uart0_rx.
// Checks
//   1. SAMPLE/PRELOAD: the captured cells equal the pin/core values, the pins
//      stay functional, and a pattern is preloaded.
//   2. EXTEST: the pins take the preloaded values at Update-IR; capture sees
//      the pin levels; a second pattern reaches the pins at Update-DR.
//   3. INTEST: the input cells drive the core, the pins keep their values.
//   4. BYPASS: the pins and the core inputs are functional again.
// Cell numbers as in cc_bscan.sv / bsdl/cc_chip_top.bsd.
module tb_rv64i ();
  localparam int tclk_2_t = 500;   // half TCK period, 1 MHz TCK
  localparam int clk_2_t  = 5;     // 100 MHz clk_i
  localparam int n_cells  = 2 + 3*nr_gpios + 3;  // tx, cs; 3 per GPIO; rx, rst, clk
  localparam int c_tx     = 0;
  localparam int c_cs     = 1;
  localparam int c_gpio   = 2;
  localparam int c_rx     = c_gpio + 3*nr_gpios;
  localparam int c_rst    = c_rx + 1;
  localparam int c_clk    = c_rx + 2;

  logic clk_s;
  logic rst_s;
  logic tck_s, trst_s, tms_s, tdi_s, tdo_s;
  tri   [nr_gpios-1:0] gpio_s;
  logic [nr_gpios-1:0] gpio_o_s, gpio_oe_s;
  logic                cs_s;
  logic                tx_s;
  logic                rx_s;
  logic                tb_drive_s;       // TB drives GPIO 7..4
  logic [3:0]          tb_gpio_s;
  logic [nr_gpios-1:0] out1_s, out2_s, in1_s, in2_s;

  int   fd;
  logic [n_cells-1:0] din_s, dout_s, exp_s, pre1_s, pre2_s, mask_s;

  as_top_mem DUT (.clk_i(clk_s),
                  .rst_i(rst_s),
                  .tck_i(tck_s),
                  .trst_i(trst_s),
                  .tms_i(tms_s),
                  .tdi_i(tdi_s),
                  .tdo_o(tdo_s),
                  .tdo_oe_o(),
                  .gpio_o(gpio_o_s), .gpio_oe_o(gpio_oe_s), .gpio_i(gpio_s),
                  .cs_o(cs_s),
                  .uart0_tx_o(tx_s),
                  .uart0_rx_i(rx_s)
                 );

  // GPIO pins: the tri-state driver is in the pad ring (cc_chip_top)
  genvar gp;
  generate
    for (gp = 0; gp < nr_gpios; gp++)
    begin : g_gpio_pin
      assign gpio_s[gp] = gpio_oe_s[gp] ? gpio_o_s[gp] : 1'bz;
    end
    for (gp = 4; gp < 8; gp++)
    begin : g_gpio_tb
      assign gpio_s[gp] = tb_drive_s ? tb_gpio_s[gp-4] : 1'bz;
    end
  endgenerate

  always
  begin
    clk_s <= 1; #clk_2_t; clk_s <= 0; #clk_2_t;
  end

  always
  begin
    tck_s <= 0; #tclk_2_t; tck_s <= 1; #tclk_2_t;
  end

  initial
  begin
    fd         = $fopen("./error.txt", "a");
    rst_s      = 1'b1;
    trst_s     = 1'b0;     // TRST# low: TAP in Test-Logic-Reset, IR functional
    tms_s      = 1'b1;
    tdi_s      = 1'b0;
    rx_s       = 1'b1;
    tb_drive_s = 1'b0;
    tb_gpio_s  = 4'b1001;
    #(20*2*clk_2_t);
    rst_s      = 1'b0;

    // program done: GPIO 7..4 are inputs
    for (int t = 0; t < 200000 && !(gpio_oe_s == 8'h0F && gpio_o_s[3:0] == 4'b0101); t++)
      #10;
    tb_drive_s = 1'b1;
    @(negedge tck_s);
    trst_s = 1'b1;
    #(tclk_2_t/2);                       // drive a quarter period before posedge
    jtag_sw_rst(tclk_2_t);

    // 1. SAMPLE/PRELOAD
    // GPIO 3..0 enabled, 7..4 disabled (driven by the TB) in both patterns.
    // Values differ from the functional ones (GPIO 3..0 = 0101, tx = 1).
    out1_s = 8'h0A;  in1_s = 8'h3C;     // pre1: cs = 1, tx = 0, rx = 0
    out2_s = 8'h03;  in2_s = 8'hA5;     // pre2: cs = 0, tx = 1, rx = 0
    pre1_s = '0;
    pre2_s = '0;
    pre1_s[c_cs] = 1'b1;
    pre2_s[c_tx] = 1'b1;
    for (int g = 0; g < nr_gpios; g++)
    begin
      pre1_s[c_gpio + 3*g]     = (g < 4);
      pre1_s[c_gpio + 3*g + 1] = out1_s[g];
      pre1_s[c_gpio + 3*g + 2] = in1_s[g];
      pre2_s[c_gpio + 3*g]     = (g < 4);
      pre2_s[c_gpio + 3*g + 1] = out2_s[g];
      pre2_s[c_gpio + 3*g + 2] = in2_s[g];
    end
    jtag_load_ir(tclk_2_t, 8'h02);
    exp_s = capture_value();
    din_s = pre1_s;
    jtag_scan(tclk_2_t);
    check("SAMPLE captures pins and core outputs", (dout_s & mask_s) == (exp_s & mask_s));
    check("SAMPLE/PRELOAD keeps the pins functional", pins_functional());

    // 2. EXTEST
    jtag_load_ir(tclk_2_t, 8'h00);
    check("EXTEST drives the preloaded values at Update-IR", pins_equal(pre1_s));
    exp_s = capture_value();
    din_s = pre2_s;
    jtag_scan(tclk_2_t);
    check("EXTEST captures the pin levels", (dout_s & mask_s) == (exp_s & mask_s));
    check("EXTEST drives the shifted values at Update-DR", pins_equal(pre2_s));

    // 3. INTEST: same update values, input cells now drive the core
    jtag_load_ir(tclk_2_t, 8'h01);
    check("INTEST input cells drive the core", core_inputs_equal(pre2_s) && pins_equal(pre2_s));

    // 4. BYPASS
    jtag_load_ir(tclk_2_t, 8'hFF);
    check("BYPASS restores the functional pins", pins_functional());

    $fclose(fd);
    $stop;
  end

  // Expected capture: output/control cells see the core, input cells the pin.
  // The clock cell (clk_i) toggles and is not compared (mask_s).
  function automatic logic [n_cells-1:0] capture_value();
    logic [n_cells-1:0] v;
    v = '0;
    v[c_tx] = DUT.uart0_tx_s;
    v[c_cs] = DUT.asGpioCs_s;
    for (int g = 0; g < nr_gpios; g++)
    begin
      v[c_gpio + 3*g]     = DUT.gpio_oe_s[g];
      v[c_gpio + 3*g + 1] = DUT.gpio_o_s[g];
      v[c_gpio + 3*g + 2] = gpio_s[g];
    end
    v[c_rx]  = rx_s;
    v[c_rst] = rst_s;
    mask_s        = '1;
    mask_s[c_clk] = 1'b0;
    return v;
  endfunction

  function automatic bit pins_equal(logic [n_cells-1:0] v);
    bit ok;
    ok = (tx_s === v[c_tx]) && (cs_s === v[c_cs]);
    for (int g = 0; g < nr_gpios; g++)
      ok &= (gpio_oe_s[g] === v[c_gpio + 3*g]) &&
            (gpio_o_s[g]  === v[c_gpio + 3*g + 1]);
    return ok;
  endfunction

  function automatic bit core_inputs_equal(logic [n_cells-1:0] v);
    bit ok;
    ok = (DUT.uart0_rx_s === v[c_rx]);
    for (int g = 0; g < nr_gpios; g++)
      ok &= (DUT.gpio_i_s[g] === v[c_gpio + 3*g + 2]);
    return ok;
  endfunction

  function automatic bit pins_functional();
    return (gpio_o_s === DUT.gpio_o_s) && (gpio_oe_s === DUT.gpio_oe_s) &&
           (cs_s === DUT.asGpioCs_s) && (tx_s === DUT.uart0_tx_s) &&
           (DUT.gpio_i_s === gpio_s) && (DUT.uart0_rx_s === rx_s);
  endfunction

  task check(string what, bit ok);
  begin
    $display("%s: %s", ok ? "OK  " : "FAIL", what);
    $fdisplay(fd, "%s - boundary scan, %s: %s", get_time(), what,
              ok ? "Test ok" : "Test fail");
  end
  endtask

//------------------------------------------
// JTAG tasks
//------------------------------------------

  task jtag_sw_rst(int cl_2_t);
  begin
    tms_s = 1; #(5*2*cl_2_t);
    tms_s = 0; #(2*cl_2_t);            // Run-Test/Idle
  end
  endtask

  // From Test-Logic-Reset or Run-Test/Idle, back to Run-Test/Idle.
  task jtag_load_ir(int cl_2_t, logic [7:0] ir);
  begin
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

  // From Run-Test/Idle: Capture-DR, n_cells x Shift-DR, Update-DR, back to
  // Run-Test/Idle. din_s[k] ends up in cell k; dout_s[k] is the value cell k
  // captured (cell 0 is next to TDO, so it comes out first).
  task jtag_scan(int cl_2_t);
  begin
    tdi_s = 0; tms_s = 1; #(2*cl_2_t); // -> Select-DR-Scan
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // -> Capture-DR
    tdi_s = 0; tms_s = 0; #(2*cl_2_t); // -> Shift-DR
    for (int i = 0; i < n_cells; i++)
    begin
      tdi_s = din_s[i];
      tms_s = (i == n_cells - 1);       // last bit: -> Exit1-DR
      @(posedge tck_s);
      dout_s[i] = tdo_s;
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
