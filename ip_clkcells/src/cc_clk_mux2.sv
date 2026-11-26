// cc_clk_mux2.sv
//
// Clock multiplexer, 2:1.
//   `define XFAB_CLKCELLS : X-FAB XH018 D_CELLS_HD library cell; cell and pin
//                           names (XFAB_CLKMUX, XFAB_CLKMUX_I0/_I1/_S/_Q) come
//                           from $XFAB_PATHS, so no X-FAB name is in the repo
//   default               : behavioural model (simulation, FPGA)
//
// A fixed library cell keeps synthesis from building the mux out of arbitrary
// gates (glitches, unbalanced clock paths) and gives CTS and STA a defined
// clock pin. Genus must not touch it: 01b_rv64_syn.tcl preserves the instance.
`timescale 1ns/1ps

module cc_clk_mux2 (input  logic clk0_i,  // selected with sel_i = 0
                    input  logic clk1_i,  // selected with sel_i = 1
                    input  logic sel_i,   // static while the clocks run
                    output logic clk_o
                   );

`ifdef XFAB_CLKCELLS

  `XFAB_CLKMUX u_cell (.`XFAB_CLKMUX_I0(clk0_i),
                       .`XFAB_CLKMUX_I1(clk1_i),
                       .`XFAB_CLKMUX_S (sel_i),
                       .`XFAB_CLKMUX_Q (clk_o));

`else

  // CLOCK GATE: clock multiplexer, behavioural model of the library cell
  assign clk_o = sel_i ? clk1_i : clk0_i;

`endif

endmodule : cc_clk_mux2
