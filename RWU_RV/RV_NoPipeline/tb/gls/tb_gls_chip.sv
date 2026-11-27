
`timescale 1ns/1ps

import as_pack::*;

// Chip-level testbench for the gate-level simulation (scripts/gatesim).
//
// The DUT is cc_chip_top: the synthesized netlist, or the RTL with the
// behavioural pads as reference. The testbench only uses the bond pads --
// no hierarchical reference into the DUT -- so that it runs unchanged on
// both.
//
// The program is loaded through JTAG (instruction I_MEM), as on silicon:
// the SPRAM model has no $readmemh start-up content. gatesim.sh copies the
// memory image to gls_prog.mem (NOT riscvtest.mem, so that the RTL reference
// run does not preload the I-Mem either).
//
// +MODE=instr   (default) instruction test: like tb_rv64i_instr.sv, the test
//               passes when the GPIO pins show +EXPECTED=<n> while cs_o is 1
//               (+TEST_NAME=<label>)
// +MODE=scan    scan test through SCANTEST: a random pattern from TDI comes
//               out at TDO delayed by the chain length +SCAN_LENGTH=<n>
//               (RTL: 0; netlist: the length in cc_chip_top_scan_chains.rpt)
// +MODE=bscan   boundary scan, program instr99bscan: SAMPLE/PRELOAD and
//               EXTEST, checked at the pins
// +TIMEOUT_US=<n> simulated time limit (default 20000 us)
module tb_gls ();
  localparam int tck_2_t  = 50;    // half TCK period, 10 MHz
  localparam int clk_2_t  = 5;     // 100 MHz clk_i
  localparam int n_cells  = 2 + 3*nr_gpios + 3;
  localparam int c_tx     = 0;
  localparam int c_cs     = 1;
  localparam int c_gpio   = 2;
  localparam int c_rx     = c_gpio + 3*nr_gpios;
  localparam int c_rst    = c_rx + 1;
  localparam int c_clk    = c_rx + 2;
  localparam int n_pat    = 64;

  logic clk_s, rst_s;
  logic tck_s, trst_s, tms_s, tdi_s;
  wire  tdo_s;
  tri   [nr_gpios-1:0] gpio_s;
  wire  cs_s, tx_s;
  logic rx_s;
  logic tb_drive_s;                      // TB drives GPIO 7..4 (bscan)
  logic [3:0] tb_gpio_s;

  logic [instr_width-1:0] prog_s [imemdepth];
  int   fd;
  string mode, test_name;
  int   expected, cs_count, timeout_us, scan_length, n_words;
  bit   done;

  logic [n_cells-1:0] din_s, dout_s, exp_s, mask_s, pre1_s, pre2_s;
  logic pat_s [];
  logic out_s [];

  cc_chip_top DUT (.clk_i(clk_s),
                   .rst_i(rst_s),
                   .tck_i(tck_s),
                   .trst_i(trst_s),
                   .tms_i(tms_s),
                   .tdi_i(tdi_s),
                   .tdo_o(tdo_s),
                   .gpio_io(gpio_s),
                   .cs_o(cs_s),
                   .uart0_tx_o(tx_s),
                   .uart0_rx_i(rx_s)
                  );

  // Board: weak pull-downs, so that an undriven pad reads 0, not Z/X.
  genvar gp;
  generate
    for (gp = 0; gp < nr_gpios; gp++)
    begin : g_pd
      pulldown pd (gpio_s[gp]);
    end
    for (gp = 4; gp < 8; gp++)
    begin : g_tb
      assign gpio_s[gp] = tb_drive_s ? tb_gpio_s[gp-4] : 1'bz;
    end
  endgenerate

  always
  begin
    clk_s <= 1; #clk_2_t; clk_s <= 0; #clk_2_t;
  end

  always
  begin
    tck_s <= 0; #tck_2_t; tck_s <= 1; #tck_2_t;
  end

  // ---------------------------------------------------------------------
  // Main sequence
  // ---------------------------------------------------------------------
  initial
  begin
    fd = $fopen("./error.txt", "a");
    if (!$value$plusargs("MODE=%s", mode))              mode        = "instr";
    if (!$value$plusargs("TEST_NAME=%s", test_name))    test_name   = mode;
    if (!$value$plusargs("EXPECTED=%d", expected))      expected    = -1;
    if (!$value$plusargs("TIMEOUT_US=%d", timeout_us))  timeout_us  = 20000;
    if (!$value$plusargs("SCAN_LENGTH=%d", scan_length)) scan_length = 0;
    done       = 0;
    cs_count   = 0;
    rst_s      = 1'b1;
    trst_s     = 1'b0;                   // TRST# low: TAP in Test-Logic-Reset
    tms_s      = 1'b1;
    tdi_s      = 1'b0;
    rx_s       = 1'b1;
    tb_drive_s = 1'b0;
    tb_gpio_s  = 4'b1001;
    #(20*2*clk_2_t);
    @(negedge tck_s);
    trst_s = 1'b1;
    #(tck_2_t/2);                        // drive a quarter period before posedge
    jtag_sw_rst();

    if (mode == "scan")
      run_scan();
    else
    begin
      load_program();
      jtag_load_ir(8'hFF);               // leave I_MEM: I-Mem clock back to clk_i
      rst_s = 1'b0;
      if (mode == "bscan")
        run_bscan();
      // instr: decided by the cs_o monitor below
    end
  end

  initial
  begin
    #1;
    #(longint'(timeout_us) * 1000);
    if (!done)
      finish_test("timeout", 0);
  end

  // ---------------------------------------------------------------------
  // Program load through JTAG (IR I_MEM = 0x80)
  // ---------------------------------------------------------------------
  // Only non-zero words are written: the image is zero-filled up to the ISR
  // at 0x7F00, and the CPU only fetches what it executes.
  task load_program();
  begin
    foreach (prog_s[i]) prog_s[i] = '0;
    $readmemh("gls_prog.mem", prog_s);
    jtag_load_ir(8'h80);
    n_words = 0;
    for (int i = 0; i < imemdepth; i++)
      if (prog_s[i] !== '0 && !$isunknown(prog_s[i]))
      begin
        jtag_imem_write(15'(4*i), prog_s[i]);
        n_words++;
      end
    $display("JTAG: %0d words loaded into the I-Mem", n_words);
  end
  endtask

  // I-Mem chain: {byte address, data, write enable}, MSB shifted first
  task jtag_imem_write(logic [imem_addr_width-1:0] addr, logic [instr_width-1:0] data);
    logic [im_scan_length-1:0] dr;
  begin
    dr = {addr, data, 1'b1};
    tdi_s = 0; tms_s = 1; #(2*tck_2_t); // Select-DR-Scan
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // Capture-DR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // Shift-DR
    for (int i = im_scan_length-1; i > 0; i--)
    begin
      tdi_s = dr[i]; tms_s = 0; #(2*tck_2_t);
    end
    tdi_s = dr[0]; tms_s = 1; #(2*tck_2_t); // Exit1-DR
    tdi_s = 0; tms_s = 1; #(2*tck_2_t);     // Update-DR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t);     // Run-Test/Idle
  end
  endtask

  // ---------------------------------------------------------------------
  // MODE=instr: result on the GPIO pins while cs_o = 1
  // ---------------------------------------------------------------------
  always @(posedge cs_s)
  begin
    if (mode == "instr" && !done)
    begin
      #(20*clk_2_t);                     // pins settled (SDF delays)
      cs_count++;
      $display("CS #%0d: gpio=0x%0h  expected=0x%0h", cs_count, gpio_s, expected);
      if (gpio_s === 8'(expected))
        finish_test(test_name, 1);
      else if (cs_count >= 20)
        finish_test(test_name, 0);
    end
  end

  // ---------------------------------------------------------------------
  // MODE=scan
  // ---------------------------------------------------------------------
  task run_scan();
    int delay, n_shift, errors;
  begin
    // TDO is sampled one rising edge after the falling edge that loads the
    // TDO register: chain length 0 still delays by one cycle.
    delay   = (scan_length == 0) ? 1 : scan_length;
    n_shift = delay + n_pat;
    jtag_load_ir(8'h81);                 // SCANTEST
    rst_s = 1'b0;                        // scan flip-flops out of reset
    pat_s = new[n_shift];
    out_s = new[n_shift];
    foreach (pat_s[i])
      pat_s[i] = 1'($urandom_range(1, 0));
    tdi_s = 0; tms_s = 1; #(2*tck_2_t); // -> Select-DR-Scan
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // -> Capture-DR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // -> Shift-DR
    for (int i = 0; i < n_shift; i++)
    begin
      tdi_s = pat_s[i];
      tms_s = (i == n_shift - 1);
      @(posedge tck_s);
      out_s[i] = tdo_s;
      #(tck_2_t + tck_2_t/2);
    end
    tdi_s = 0; tms_s = 1; #(2*tck_2_t); // -> Update-DR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // -> Run-Test/Idle
    errors = 0;
    for (int i = delay; i < n_shift; i++)
      if (out_s[i] !== pat_s[i - delay])
        errors++;
    $display("scan: chain length %0d, %0d bit errors", scan_length, errors);
    finish_test($sformatf("scan chain length %0d", scan_length), errors == 0);
  end
  endtask

  // ---------------------------------------------------------------------
  // MODE=bscan (program instr99bscan: GPIO 3..0 out = 0101, 7..4 inputs)
  // ---------------------------------------------------------------------
  task run_bscan();
    logic [nr_gpios-1:0] out1, out2;
    bit ok;
  begin
    for (int t = 0; t < 100000 && gpio_s[3:0] !== 4'b0101; t++)
      #(10*clk_2_t);
    #(2000*clk_2_t);                     // program has reached its end loop
    tb_drive_s = 1'b1;

    // pre1: GPIO 3..0 enabled = 1010, 7..4 off; cs = 1, tx = 0
    // pre2: GPIO 2..0 enabled = 011, GPIO 3 off (pull-down -> 0, although
    //       its output cell holds 1); cs = 0, tx = 1
    out1 = 8'h0A;
    out2 = 8'h0B;
    pre1_s = '0;
    pre2_s = '0;
    pre1_s[c_cs] = 1'b1;
    pre2_s[c_tx] = 1'b1;
    for (int g = 0; g < nr_gpios; g++)
    begin
      pre1_s[c_gpio + 3*g]     = (g < 4);
      pre1_s[c_gpio + 3*g + 1] = out1[g];
      pre2_s[c_gpio + 3*g]     = (g < 3);
      pre2_s[c_gpio + 3*g + 1] = out2[g];
    end

    jtag_load_ir(8'h02);                 // SAMPLE/PRELOAD
    exp_s = capture_sample();
    din_s = pre1_s;
    jtag_scan_bs();
    check("SAMPLE captures the pins", (dout_s & mask_s) === (exp_s & mask_s));
    ok = (gpio_s[3:0] === 4'b0101) && (tx_s === 1'b1);
    check("SAMPLE/PRELOAD keeps the pins functional", ok);

    jtag_load_ir(8'h00);                 // EXTEST
    check("EXTEST drives the preloaded values at Update-IR",
          gpio_s[3:0] === 4'b1010 && cs_s === 1'b1 && tx_s === 1'b0);
    exp_s = capture_extest();
    din_s = pre2_s;
    jtag_scan_bs();
    check("EXTEST captures the pin levels", (dout_s & mask_s) === (exp_s & mask_s));
    check("EXTEST drives the shifted values, control cell disables GPIO 3",
          gpio_s[3:0] === 4'b0011 && cs_s === 1'b0 && tx_s === 1'b1);

    jtag_load_ir(8'hFF);                 // BYPASS
    #(10*clk_2_t);
    finish_test("BYPASS restores the functional pins",
                gpio_s[3:0] === 4'b0101 && tx_s === 1'b1);
  end
  endtask

  // Expected SAMPLE capture, from the pins and the known program state:
  // the control cells see the core enable (GPIO 3..0 outputs); the output
  // cells of the input GPIOs (7..4) and the clock cell are not compared.
  function automatic logic [n_cells-1:0] capture_sample();
    logic [n_cells-1:0] v;
    v      = '0;
    mask_s = '1;
    v[c_tx] = tx_s;
    v[c_cs] = cs_s;
    for (int g = 0; g < nr_gpios; g++)
    begin
      v[c_gpio + 3*g]     = (g < 4);
      v[c_gpio + 3*g + 1] = gpio_s[g];
      v[c_gpio + 3*g + 2] = gpio_s[g];
      if (g >= 4)
        mask_s[c_gpio + 3*g + 1] = 1'b0;
    end
    v[c_rx]  = rx_s;
    v[c_rst] = rst_s;
    mask_s[c_clk] = 1'b0;
    return v;
  endfunction

  // In EXTEST the output and control cells capture the core again, which
  // still runs the end loop: same values as in SAMPLE. The input cells
  // capture the pins, now driven by the preloaded values.
  function automatic logic [n_cells-1:0] capture_extest();
    logic [n_cells-1:0] v;
    v = capture_sample();
    v[c_tx] = 1'b1;                      // core UART idle
    mask_s[c_cs] = 1'b0;                 // core cs_o not visible at the pin
    for (int g = 0; g < 4; g++)
    begin
      v[c_gpio + 3*g + 1] = (4'b0101 >> g) & 1;
      v[c_gpio + 3*g + 2] = gpio_s[g];
    end
    return v;
  endfunction

  // ---------------------------------------------------------------------
  // JTAG helpers
  // ---------------------------------------------------------------------
  task jtag_sw_rst();
  begin
    tms_s = 1; #(5*2*tck_2_t);
    tms_s = 0; #(2*tck_2_t);             // Run-Test/Idle
  end
  endtask

  // From Run-Test/Idle back to Run-Test/Idle
  task jtag_load_ir(logic [7:0] ir);
  begin
    tms_s = 0; #(2*tck_2_t);             // Run-Test/Idle
    tms_s = 1; #(2*tck_2_t);             // Select-DR-Scan
    tms_s = 1; #(2*tck_2_t);             // Select-IR-Scan
    tdi_s = 0; tms_s = 0; #(2*tck_2_t);  // Capture-IR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t);  // Shift-IR
    for (int i = 7; i > 0; i--)
    begin
      tdi_s = ir[i]; tms_s = 0; #(2*tck_2_t);
    end
    tdi_s = ir[0]; tms_s = 1; #(2*tck_2_t); // Exit1-IR
    tdi_s = 0; tms_s = 1; #(2*tck_2_t);     // Update-IR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t);     // Run-Test/Idle
  end
  endtask

  // Boundary-scan register: din_s[k] ends up in cell k, dout_s[k] is what
  // cell k captured (cell 0 next to TDO).
  task jtag_scan_bs();
  begin
    tdi_s = 0; tms_s = 1; #(2*tck_2_t); // -> Select-DR-Scan
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // -> Capture-DR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // -> Shift-DR
    for (int i = 0; i < n_cells; i++)
    begin
      tdi_s = din_s[i];
      tms_s = (i == n_cells - 1);
      @(posedge tck_s);
      dout_s[i] = tdo_s;
      #(tck_2_t + tck_2_t/2);
    end
    tdi_s = 0; tms_s = 1; #(2*tck_2_t); // -> Update-DR
    tdi_s = 0; tms_s = 0; #(2*tck_2_t); // -> Run-Test/Idle
  end
  endtask

  // ---------------------------------------------------------------------
  // Result
  // ---------------------------------------------------------------------
  task check(string what, bit ok);
  begin
    $display("%s: %s", ok ? "OK  " : "FAIL", what);
    $fdisplay(fd, "%s - gls %s, %s: %s", get_time(), mode, what,
              ok ? "Test ok" : "Test fail");
  end
  endtask

  task finish_test(string what, bit ok);
  begin
    check(what, ok);
    done = 1;
    $fclose(fd);
    $stop;
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

endmodule : tb_gls
