
// asDecode.sv
`timescale 1ns/1ps

import as_pack::*;

module as_decode (input  logic [daddr_width-1:0] addr_i,
                  output logic [chipsel-1:0]     cs_o);

  always_comb
  begin
    case (addr_i) inside
      [64'h00000000_00000000:64'h00000000_0000FFFF]: cs_o = 6'b000001; // DMem   64 kByte
      [64'h00000001_00000000:64'h00000001_000001FF]: cs_o = 6'b000010; // GPIO   512 B
      [64'h00000001_00000200:64'h00000001_000003FF]: cs_o = 6'b000100; // QSPI   512 B
      [64'h00000001_00000400:64'h00000001_000005FF]: cs_o = 6'b001000; // CGU    512 B
      [64'h00000001_00000600:64'h00000001_000007FF]: cs_o = 6'b010000; // UART0  512 B
      [64'h00000001_00000800:64'h00000001_000009FF]: cs_o = 6'b100000; // ICU0   512 B
      default:                                       cs_o = 6'b000000;
    endcase
  end
  
  
endmodule : as_decode

