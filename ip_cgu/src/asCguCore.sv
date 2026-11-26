// asCguCore.sv
`timescale 1ns/1ps

import as_pack::*;

// Every divided clock comes straight from a flip-flop: a decoded counter
// value (cnt < div/2) can glitch while the counter bits switch, and a glitch
// on a clock line is an extra clock edge. The registered compare has the same
// waveform, delayed by one clk_i cycle.
module as_cgucore (input  logic clk_i, // external clock (Zybo: 125 MHz)
                   input  logic rst_i,
                   output logic clk_bus1_o,
                   output logic clk_bus2_o,
                   output logic clk_qspi_o,
                   output logic clk_core_o);
  int   cnt1_r,cnt2_r,cnt3_r,cnt4_r;
  logic clk_core_r, clk_qspi_r, clk_bus1_r, clk_bus2_r;

  assign clk_core_o = clk_core_r;
  assign clk_qspi_o = clk_qspi_r;
  assign clk_bus1_o = clk_bus1_r;
  assign clk_bus2_o = clk_bus2_r;

  // core clock
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
    begin
      cnt1_r     <= 0;
      clk_core_r <= 1'b1;
    end
    else
    begin
      if( cnt1_r >= (clk_core_div-1) )
        cnt1_r <= 0;
      else
        cnt1_r <= cnt1_r + 1;
      clk_core_r <= (cnt1_r < (clk_core_div/2));
    end
  end // always_ff @ (posedge clk_i, posedge rst_i)

  // qspi clock
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
    begin
      cnt2_r     <= 0;
      clk_qspi_r <= 1'b1;
    end
    else
    begin
      if( cnt2_r >= (clk_qspi_div-1) )
        cnt2_r <= 0;
      else
        cnt2_r <= cnt2_r + 1;
      clk_qspi_r <= (cnt2_r < ((clk_qspi_div-1)/2));
    end
  end // always_ff @ (posedge clk_i, posedge rst_i)

  // bus1 clock
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
    begin
      cnt3_r     <= 0;
      clk_bus1_r <= 1'b1;
    end
    else
    begin
      if( cnt3_r >= (clk_bus1_div-1) )
        cnt3_r <= 0;
      else
        cnt3_r <= cnt3_r + 1;
      clk_bus1_r <= (cnt3_r < (clk_bus1_div/2));
    end
  end // always_ff @ (posedge clk_i, posedge rst_i)

  // bus2 clock
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
    begin
      cnt4_r     <= 0;
      clk_bus2_r <= 1'b1;
    end
    else
    begin
      if( cnt4_r >= (clk_bus2_div-1) )
        cnt4_r <= 0;
      else
        cnt4_r <= cnt4_r + 1;
      clk_bus2_r <= (cnt4_r < (clk_bus2_div/2));
    end
  end // always_ff @ (posedge clk_i, posedge rst_i)

endmodule : as_cgucore
