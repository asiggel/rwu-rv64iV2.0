
// asDMemCore.sv
//
// D-Mem array, 1024 x 64 bit, byte write, registered read.
//   `define XFAB_SPRAM : X-FAB XH018 SPRAM macro with bit write mask
//   default            : behavioural model (xsim, Verilator/cocotb, Vivado)
`timescale 1ns/1ps

import as_pack::*;

module as_dmem_core (input  logic                       clk_i,
                     input  logic [dmem_addr_width-1:3] addr_i,
                     input  logic                       wrEn_i,
                     /* verilator lint_off UNUSEDSIGNAL */ // the read register is updated every cycle
                     input  logic                       rdEn_i,
                     /* verilator lint_on UNUSEDSIGNAL */
                     input  logic [reg_width-1:0]       data_i,
                     input  logic [7:0]                 byteEn_i,
                     output logic [reg_width-1:0]       data_o
               );

  logic [7:0]           byteWr_s;
`ifdef XFAB_SPRAM
  logic [reg_width-1:0] wen_s;
`else
  (* ram_style = "block" *) logic [reg_width-1:0] ram_s[dmemdepth-1:0];
`endif

  assign byteWr_s = {8{wrEn_i}} & byteEn_i;

`ifdef XFAB_SPRAM

  // Bit write mask, active low: each byte enable drives the 8 bits of its byte.
  genvar i;
  generate
    for (i = 0; i < 8; i++)
    begin : g_wen
      assign wen_s[8*i+7:8*i] = {8{~byteWr_s[i]}};
    end
  endgenerate

  // CEn tied active: as_dmem_back expects the read register to be updated in
  // every cycle (address in EXEC_ST, data taken in EXECLD_ST).
  // XFAB_DMEM_MACRO: SPRAM cell name, set by 00_rv64_elab.tcl from $XFAB_PATHS
  `XFAB_DMEM_MACRO spram (.CLK(clk_i),
                               .CEn(1'b0),
                               .WEn(wen_s),
                               .A(addr_i),
                               .D(data_i),
                               .Q(data_o),
                               .RDY()
                              );

`else

  genvar i;
  generate
    for (i = 0; i < 8; i++)
    begin : g_byte
      always_ff @(posedge clk_i)
      begin
        if (byteWr_s[i])
          ram_s[addr_i][8*i+7:8*i] <= data_i[8*i+7:8*i];
      end
    end
  endgenerate

  always_ff @(posedge clk_i)
  begin
    data_o <= ram_s[addr_i];
  end

`endif

endmodule : as_dmem_core
