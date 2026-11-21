
// cc_pad_in.sv
//
// Input pad.
//   `define XFAB_PADS : X-FAB XH018 IO_CELLS_3V input cell; the cell names
//                       (XFAB_PAD_IN, XFAB_PAD_IN_ST) come from $XFAB_PATHS
//   default           : behavioural model (simulation, FPGA)
`timescale 1ns/1ps

/* verilator lint_off UNUSEDPARAM */ // used only with XFAB_PADS
module cc_pad_in #(parameter bit schmitt = 1'b0)  // Schmitt-trigger input
                  (input  logic pad_i,
                   output logic y_o
                  );

`ifdef XFAB_PADS

  // PI/PO form the NAND tree for parametric pad test; not used, PI tied low.
  generate
    if (schmitt)
    begin : g_st
      `XFAB_PAD_IN_ST pad (.PAD(pad_i), .Y(y_o), .PI(1'b0), .PO());
    end
    else
    begin : g_cmos
      `XFAB_PAD_IN pad (.PAD(pad_i), .Y(y_o), .PI(1'b0), .PO());
    end
  endgenerate

`else

  assign y_o = pad_i;

`endif

endmodule : cc_pad_in
