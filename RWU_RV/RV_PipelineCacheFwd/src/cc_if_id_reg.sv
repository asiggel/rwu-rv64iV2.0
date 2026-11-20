// cc_if_id_reg.sv  –  RV_PipelineCacheFwd: IF/ID pipeline register
//
//   flush_i   → NOP, invalid
//   advance_i → load from ibuf (if valid) else directly from the I-cache
//
// An I-cache AXI4 error enters as a NOP with fault_o set, so the fault
// travels down the pipe and traps in WB like any other exception.
`timescale 1ns/1ps

import as_pack::*;

module cc_if_id_reg (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    flush_i,
    input  logic                    advance_i,
    input  logic                    ibuf_valid_i,
    input  logic [instr_width-1:0]  ibuf_instr_i,
    input  logic [iaddr_width-1:0]  ibuf_pc_i,
    input  logic                    ibuf_fault_i,
    input  logic [instr_width-1:0]  ic_rdata_i,
    input  logic                    ic_err_i,
    input  logic [iaddr_width-1:0]  fetch_pc_i,
    output logic [instr_width-1:0]  instr_o,
    output logic [iaddr_width-1:0]  pc_o,
    output logic                    valid_o,
    output logic                    fault_o
);

  localparam logic [instr_width-1:0] NOP_INSTR = 32'h00000013;

  logic [instr_width-1:0] instr_r;
  logic [iaddr_width-1:0] pc_r;
  logic                   valid_r;
  logic                   fault_r;

  assign instr_o = instr_r;
  assign pc_o    = pc_r;
  assign valid_o = valid_r;
  assign fault_o = fault_r;

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      instr_r <= NOP_INSTR;
      pc_r    <= 64'h0;
      valid_r <= 1'b0;
      fault_r <= 1'b0;
    end else begin
      if (flush_i) begin
        instr_r <= NOP_INSTR;
        valid_r <= 1'b0;
        fault_r <= 1'b0;
      end else if (advance_i) begin
        valid_r <= 1'b1;
        if (ibuf_valid_i) begin
          instr_r <= ibuf_instr_i;
          pc_r    <= ibuf_pc_i;
          fault_r <= ibuf_fault_i;
        end else begin
          instr_r <= ic_err_i ? NOP_INSTR : ic_rdata_i;
          pc_r    <= fetch_pc_i;
          fault_r <= ic_err_i;
        end
      end
    end
  end

endmodule : cc_if_id_reg
