
// cc_chip_top.sv
//
// Chip top of RV_NoPipeline (Variant A, X-FAB XH018): pad ring + as_top_mem.
// The ports are the bond pads; their names match the as_top_mem ports, so
// that the SDC port names hold for both levels.
//   `define XFAB_PADS : IO_CELLS_3V pad cells and supply pads (Genus)
//   default           : behavioural pads, no supply pads (simulation, FPGA)
`timescale 1ns/1ps

import as_pack::*;

module cc_chip_top (input  logic                clk_i,
                    input  logic                rst_i,
                    // JTAG
                    input  logic                tck_i,
                    input  logic                trst_i,
                    input  logic                tms_i,
                    input  logic                tdi_i,
                    output tri                  tdo_o,
                    // GPIO
                    inout  tri   [nr_gpios-1:0] gpio_io,
                    output tri                  cs_o,
                    // UART0
                    output tri                  uart0_tx_o,
                    input  logic                uart0_rx_i
                   );

  logic                clk_s;
  logic                rst_s;
  logic                tck_s;
  logic                trst_s;
  logic                tms_s;
  logic                tdi_s;
  logic                tdo_s;
  logic                tdo_oe_s;
  logic [nr_gpios-1:0] gpio_o_s;
  logic [nr_gpios-1:0] gpio_oe_s;
  logic [nr_gpios-1:0] gpio_i_s;
  logic                cs_s;
  logic                uart0_tx_s;
  logic                uart0_rx_s;

  // ---- GPIO pads --------------------------------------------------------
  genvar g;
  generate
    for (g = 0; g < nr_gpios; g++)
    begin : g_gpio
      cc_pad_bidir pad (.a_i(gpio_o_s[g]),
                        .oe_i(gpio_oe_s[g]),
                        .y_o(gpio_i_s[g]),
                        .pad_io(gpio_io[g])
                       );
    end
  endgenerate

  // ---- Supply pads (X-FAB only) -------------------------------------------
  // Two pads per supply role; the cells per role come from $XFAB_PATHS.
  // Count and roles are a first estimate (spec, Pad Ring, TECH-06).
`ifdef XFAB_PADS
  generate
    for (g = 0; g < 2; g++)
    begin : g_supply
      `XFAB_PAD_VDD  vdd_core ();
      `XFAB_PAD_GND  gnd_core ();
      `XFAB_PAD_VDDO vdd_io ();
      `XFAB_PAD_GNDO gnd_io ();
    end
  endgenerate
`endif

  // ---- Input pads -------------------------------------------------------
  // clk_i (100 MHz) uses the CMOS input; the slow clock and reset inputs
  // use Schmitt triggers against noise on the board.
  cc_pad_in #(.schmitt(1'b0)) pad_clk     (.pad_i(clk_i),      .y_o(clk_s));
  cc_pad_in #(.schmitt(1'b1)) pad_rst     (.pad_i(rst_i),      .y_o(rst_s));
  cc_pad_in #(.schmitt(1'b1)) pad_tck     (.pad_i(tck_i),      .y_o(tck_s));
  cc_pad_in #(.schmitt(1'b1)) pad_trst    (.pad_i(trst_i),     .y_o(trst_s));
  cc_pad_in #(.schmitt(1'b0)) pad_tms     (.pad_i(tms_i),      .y_o(tms_s));
  cc_pad_in #(.schmitt(1'b0)) pad_tdi     (.pad_i(tdi_i),      .y_o(tdi_s));
  cc_pad_in #(.schmitt(1'b0)) pad_uart_rx (.pad_i(uart0_rx_i), .y_o(uart0_rx_s));

  // ---- Output pads ------------------------------------------------------
  // TDO is high impedance outside Shift-IR/Shift-DR (IEEE 1149.1).
  cc_pad_out pad_tdo     (.a_i(tdo_s),      .oe_i(tdo_oe_s), .pad_o(tdo_o));
  cc_pad_out pad_cs      (.a_i(cs_s),       .oe_i(1'b1),     .pad_o(cs_o));
  cc_pad_out pad_uart_tx (.a_i(uart0_tx_s), .oe_i(1'b1),     .pad_o(uart0_tx_o));

  // ---- Core -------------------------------------------------------------
  as_top_mem core (.clk_i(clk_s),
                   .rst_i(rst_s),
                   .tck_i(tck_s),
                   .trst_i(trst_s),
                   .tms_i(tms_s),
                   .tdi_i(tdi_s),
                   .tdo_o(tdo_s),
                   .tdo_oe_o(tdo_oe_s),
                   .gpio_o(gpio_o_s),
                   .gpio_oe_o(gpio_oe_s),
                   .gpio_i(gpio_i_s),
                   .cs_o(cs_s),
                   .uart0_tx_o(uart0_tx_s),
                   .uart0_rx_i(uart0_rx_s)
                  );

endmodule : cc_chip_top
