// cc_clk_gate.sv
//
// Integrated clock gate (ICG): latch on the low clock phase + AND, so that
// an enable change while clk_i is high cannot cut a clock pulse.
//   `define XFAB_CLKCELLS : X-FAB XH018 D_CELLS_HD clock gating cell; cell and
//                           pin names (XFAB_ICG, XFAB_ICG_CK/_E/_TE/_Q) come
//                           from $XFAB_PATHS, so no X-FAB name is in the repo
//   default               : behavioural model (simulation, FPGA)
//
// en_i must come from flip-flops clocked on the rising edge of clk_i.
`timescale 1ns/1ps

module cc_clk_gate (input  logic clk_i,
                    input  logic en_i,    // functional enable
                    input  logic te_i,    // test enable: clock always on
                    output logic gclk_o
                   );

`ifdef XFAB_CLKCELLS

  `XFAB_ICG u_cell (.`XFAB_ICG_CK(clk_i),
                    .`XFAB_ICG_E (en_i),
                    .`XFAB_ICG_TE(te_i),
                    .`XFAB_ICG_Q (gclk_o));

`else

  logic en_lat_s;

  // CLOCK GATE: behavioural model of the library ICG cell
  always_latch
  begin
    if (!clk_i)
      en_lat_s = en_i | te_i;
  end

  // CLOCK GATE: behavioural model of the library ICG cell
  assign gclk_o = clk_i & en_lat_s;

`endif

endmodule : cc_clk_gate
