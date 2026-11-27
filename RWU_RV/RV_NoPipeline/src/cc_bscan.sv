// cc_bscan.sv
//
// Boundary-scan register of RV_NoPipeline (IEEE 1149.1), between the pads
// (cc_chip_top) and the core logic of as_top_mem. Described for test tools in
// bsdl/cc_chip_top.bsd -- the cell numbers there are the indices below, keep
// both in step.
//
// Cell 0 is next to TDO, TDI enters the highest cell:
//    0          uart0_tx_o   output2 (BC_1)
//    1          cs_o         output2 (BC_1)
//    2 + 3*g    gpio_io(g)   control (BC_1), 1 = output enabled
//    3 + 3*g    gpio_io(g)   output3 (BC_1), controlled by cell 2 + 3*g
//    4 + 3*g    gpio_io(g)   input   (BC_1)
//   26          uart0_rx_i   input   (BC_1)
//   27          rst_i        observe_only (BC_4)
//   28          clk_i        clock        (BC_4)
//
// clk_i and rst_i are observe-only: a mux in the clock or reset path would
// put combinational logic on the clock tree and the asynchronous reset.
// Each cell is a dr_cell: capture/shift flip-flop + update flip-flop, the
// output selects the update value while mode = 1.
//   EXTEST          output and control cells drive the pins
//   INTEST          output and control cells drive the pins (held at the
//                   preloaded values), input cells drive the core
//   SAMPLE/PRELOAD  transparent; capture and shift only
`timescale 1ns/1ps

import as_pack::*;

module cc_bscan (input  logic                tck_i,
                 input  logic                trst_i,     // TAP reset, active high
                 input  logic                shift_i,
                 input  logic                clock_i,
                 input  logic                upd_i,
                 input  logic                extest_i,
                 input  logic                intest_i,
                 input  logic                tdi_i,
                 output logic                tdo_o,
                 // pin side (pads)
                 input  logic                pin_clk_i,
                 input  logic                pin_rst_i,
                 input  logic                pin_uart0_rx_i,
                 input  logic [nr_gpios-1:0] pin_gpio_i,
                 output logic [nr_gpios-1:0] pin_gpio_o,
                 output logic [nr_gpios-1:0] pin_gpio_oe_o,
                 output logic                pin_cs_o,
                 output logic                pin_uart0_tx_o,
                 // core side
                 output logic                core_uart0_rx_o,
                 output logic [nr_gpios-1:0] core_gpio_i_o,
                 input  logic [nr_gpios-1:0] core_gpio_o_i,
                 input  logic [nr_gpios-1:0] core_gpio_oe_i,
                 input  logic                core_cs_i,
                 input  logic                core_uart0_tx_i
                );

  localparam int n_cells  = 2 + 3*nr_gpios + 3;  // tx, cs; 3 per GPIO; rx, rst, clk
  localparam int c_tx     = 0;
  localparam int c_cs     = 1;
  localparam int c_gpio   = 2;                    // + 3*g: control, output, input
  localparam int c_rx     = c_gpio + 3*nr_gpios;
  localparam int c_rst    = c_rx + 1;
  localparam int c_clk    = c_rx + 2;

  logic               drive_pins_s;
  logic [n_cells-1:0] cap_s;      // capture value of each cell
  logic [n_cells-1:0] mode_s;
  // The observe-only cells (rst, clk) have no parallel output.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [n_cells-1:0] par_s;      // parallel output: cap_s or update value
  /* verilator lint_on UNUSEDSIGNAL */
  logic [n_cells:0]   ser_s;

  assign drive_pins_s = extest_i | intest_i;

  assign ser_s[n_cells] = tdi_i;
  assign tdo_o          = ser_s[0];

  // outputs: capture the core value, drive the pin
  assign cap_s[c_tx]    = core_uart0_tx_i;
  assign mode_s[c_tx]   = drive_pins_s;
  assign pin_uart0_tx_o = par_s[c_tx];

  assign cap_s[c_cs]    = core_cs_i;
  assign mode_s[c_cs]   = drive_pins_s;
  assign pin_cs_o       = par_s[c_cs];

  // input: capture the pin, drive the core in INTEST
  assign cap_s[c_rx]     = pin_uart0_rx_i;
  assign mode_s[c_rx]    = intest_i;
  assign core_uart0_rx_o = par_s[c_rx];

  // BOUNDARY SCAN: observe only. clk_i and rst_i are captured as data -- the
  // one place where they are not on a clock/reset pin (CLAUDE.md rule 8):
  // IEEE 1149.1 wants a cell on every system pin, and a capture flip-flop on
  // the pin side adds no logic to the clock tree or the reset network.
  assign cap_s[c_rst]  = pin_rst_i;
  assign mode_s[c_rst] = 1'b0;
  assign cap_s[c_clk]  = pin_clk_i;
  assign mode_s[c_clk] = 1'b0;

  genvar g, k;
  generate
    for (g = 0; g < nr_gpios; g++)
    begin : g_gpio
      assign cap_s[c_gpio + 3*g]     = core_gpio_oe_i[g];
      assign mode_s[c_gpio + 3*g]    = drive_pins_s;
      assign pin_gpio_oe_o[g]        = par_s[c_gpio + 3*g];

      assign cap_s[c_gpio + 3*g + 1]  = core_gpio_o_i[g];
      assign mode_s[c_gpio + 3*g + 1] = drive_pins_s;
      assign pin_gpio_o[g]            = par_s[c_gpio + 3*g + 1];

      assign cap_s[c_gpio + 3*g + 2]  = pin_gpio_i[g];
      assign mode_s[c_gpio + 3*g + 2] = intest_i;
      assign core_gpio_i_o[g]         = par_s[c_gpio + 3*g + 2];
    end

    for (k = 0; k < n_cells; k++)
    begin : g_cell
      dr_cell bs_cell (.tck_i(tck_i),
                       .trst_i(trst_i),
                       .dr_shift_i(shift_i),
                       .dr_clock_i(clock_i),
                       .dr_upd_i(upd_i),
                       .mode_i(mode_s[k]),
                       .data_i(cap_s[k]),
                       .ser_i(ser_s[k+1]),
                       .data_o(par_s[k]),
                       .ser_o(ser_s[k])
                      );
    end
  endgenerate

endmodule : cc_bscan
