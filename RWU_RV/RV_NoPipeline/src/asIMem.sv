
// asIMem.sv
//
// I-Mem, 8192 x 32 bit, single port.
//   `define XFAB_SPRAM : X-FAB XH018 low-power SPRAM macro (Genus, 00_rv64_elab.tcl)
//   default            : behavioural model with the same clocking, used by
//                        xsim, Verilator/cocotb and the Vivado FPGA build
`timescale 1ns/1ps

import as_pack::*;

module as_imem (input  logic                       tck_i,
                input  logic                       clk_i,
                input  logic                       im_mode_i,  // JTAG I_MEM instruction active
                input  logic [imem_addr_width-1:0] addr_i,
                input  logic [instr_width-1:0]     data_i,
                input  logic                       wr_i,
                output logic [instr_width-1:0]     data_o
               );

  parameter int mdepth = imemdepth;

  logic                       mem_clk_s;
  logic                       cen_s;
  logic                       wen_s;
  logic [imem_addr_width-3:0] word_addr_s;
`ifndef XFAB_SPRAM
  (* ram_style = "block" *) logic [instr_width-1:0] iram_s[mdepth-1:0];
`endif

  // CLOCK GATE: the single-port macro has one clock. JTAG loading clocks it
  // with tck_i, the CPU with clk_i. im_mode_i comes from the JTAG IR and is
  // static while loading; load only with rst_i = 1, so that clk_core stands
  // still when the IR switches (spec, I-Mem load procedure).
  assign mem_clk_s = im_mode_i ? tck_i : clk_i;

  // Load mode: only the JTAG write cycles access the macro.
  // Function mode: a read in every cycle, as the CPU fetch expects.
  assign cen_s       = im_mode_i & ~wr_i;
  assign wen_s       = ~(im_mode_i & wr_i);
  assign word_addr_s = addr_i[imem_addr_width-1:2];

`ifdef XFAB_SPRAM

  // XFAB_IMEM_MACRO: SPRAM cell name, set by 00_rv64_elab.tcl from $XFAB_PATHS
  `XFAB_IMEM_MACRO spram (.CLK(mem_clk_s),
                               .CEn(cen_s),
                               .WEn(wen_s),
                               .A(word_addr_s),
                               .D(data_i),
                               .Q(data_o),
                               .RDY()
                              );

`else

  // Simulation start-up content; on silicon JTAG loads the program.
  initial
    $readmemh("riscvtest.mem", iram_s);

  always_ff @(posedge mem_clk_s)
  begin
    if (!cen_s)
    begin
      if (!wen_s)
        iram_s[word_addr_s] <= data_i;
      else
        data_o <= iram_s[word_addr_s];
    end
  end

`endif

endmodule : as_imem
