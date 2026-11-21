
// cc_pad_bidir.sv
//
// Bidirectional pad (GPIO).
//   `define XFAB_PADS : X-FAB XH018 IO_CELLS_3V bidirectional cell; the cell
//                       name (XFAB_PAD_BIDIR) comes from $XFAB_PATHS
//   default           : behavioural model (simulation, FPGA)
`timescale 1ns/1ps

module cc_pad_bidir (input  logic a_i,    // output value
                     input  logic oe_i,   // output enable, active high
                     output logic y_o,    // input value (pad level)
                     inout  tri   pad_io
                    );

`ifdef XFAB_PADS

  // EN is active low. PI/PO (NAND tree for parametric pad test) not used.
  `XFAB_PAD_BIDIR pad (.A(a_i), .EN(~oe_i), .PAD(pad_io), .Y(y_o),
                       .PI(1'b0), .PO());

`else

  assign pad_io = oe_i ? a_i : 1'bz;
  assign y_o    = pad_io;

`endif

endmodule : cc_pad_bidir
