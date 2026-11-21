
// cc_pad_out.sv
//
// Output pad with tri-state enable.
//   `define XFAB_PADS : X-FAB XH018 IO_CELLS_3V tri-state output cell; the
//                       cell name (XFAB_PAD_OUT) comes from $XFAB_PATHS
//   default           : behavioural model (simulation, FPGA)
`timescale 1ns/1ps

module cc_pad_out (input  logic a_i,
                   input  logic oe_i,   // output enable, active high
                   output tri   pad_o
                  );

`ifdef XFAB_PADS

  // EN is active low.
  `XFAB_PAD_OUT pad (.A(a_i), .EN(~oe_i), .PAD(pad_o));

`else

  assign pad_o = oe_i ? a_i : 1'bz;

`endif

endmodule : cc_pad_out
