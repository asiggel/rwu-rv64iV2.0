// cc_mem_wb_reg.sv  –  RV_PipelineCacheFwd: MEM/WB pipeline register
//
//   flush_i        → kill control / trap flags (trap or mret in WB)
//   global_stall_i → hold
//   else           → load from MEM stage
//
// The MEM instruction is younger than the trapping/returning one in WB, so
// it must not move on into WB and commit. flush_i overrides global_stall_i
// for the same reason as in cc_id_ex_reg.
`timescale 1ns/1ps

import as_pack::*;

module cc_mem_wb_reg (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    flush_i,
    input  logic                    global_stall_i,
    input  logic                    ex_mem_valid_i,
    input  logic [instr_width-1:0]  ex_mem_instr_i,
    input  logic [iaddr_width-1:0]  ex_mem_pc_i,
    input  logic                    ex_mem_regWr_i,
    input  logic                    ex_mem_dMemRd_i,
    input  result_src_t             ex_mem_resultSrc_i,
    input  logic                    ex_mem_trap_illegal_i,
    input  logic                    ex_mem_trap_icfault_i,
    input  logic                    ex_mem_trap_misaligned_i,
    input  logic [reg_width-1:0]    ex_mem_aluRes_i,
    input  logic [reg_width-1:0]    ex_mem_csr_rdata_i,
    input  logic [reg_width-1:0]    ex_mem_csr_wdata_i,
    input  logic [reg_width-1:0]    dc_rdata_i,
    input  logic                    dc_err_i,
    input  logic [reg_width-1:0]    dc_rdata_buf_i,
    input  logic                    dc_rdata_buf_valid_i,
    input  logic                    dc_err_buf_i,
    output logic [instr_width-1:0]  instr_o,
    output logic [iaddr_width-1:0]  pc_o,
    output logic                    valid_o,
    output logic                    regWr_o,
    output result_src_t             resultSrc_o,
    output logic                    trap_illegal_o,
    output logic                    trap_icfault_o,
    output logic                    trap_dcfault_o,
    output logic                    trap_misaligned_o,
    output logic [reg_width-1:0]    aluRes_o,
    output logic [reg_width-1:0]    memData_o,
    output logic [reg_width-1:0]    csr_rdata_o,
    output logic [reg_width-1:0]    csr_wdata_o
);

  localparam int XLEN = reg_width;
  localparam logic [instr_width-1:0] NOP_INSTR = 32'h00000013;

  logic [instr_width-1:0] instr_r;
  logic [iaddr_width-1:0] pc_r;
  logic                   valid_r;
  logic                   regWr_r;
  result_src_t            resultSrc_r;
  logic                   trap_illegal_r;
  logic                   trap_icfault_r;
  logic                   trap_dcfault_r;
  logic                   trap_misaligned_r;
  logic [reg_width-1:0]   aluRes_r;
  logic [reg_width-1:0]   memData_r;
  logic [reg_width-1:0]   csr_rdata_r;
  logic [reg_width-1:0]   csr_wdata_r;

  assign instr_o           = instr_r;
  assign pc_o              = pc_r;
  assign valid_o           = valid_r;
  assign regWr_o           = regWr_r;
  assign resultSrc_o       = resultSrc_r;
  assign trap_illegal_o    = trap_illegal_r;
  assign trap_icfault_o    = trap_icfault_r;
  assign trap_dcfault_o    = trap_dcfault_r;
  assign trap_misaligned_o = trap_misaligned_r;
  assign aluRes_o          = aluRes_r;
  assign memData_o         = memData_r;
  assign csr_rdata_o       = csr_rdata_r;
  assign csr_wdata_o       = csr_wdata_r;

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      valid_r           <= 1'b0;
      instr_r           <= NOP_INSTR;
      pc_r              <= 64'h0;
      regWr_r           <= 1'b0;
      resultSrc_r       <= RES_ALU;
      trap_illegal_r    <= 1'b0;
      trap_icfault_r    <= 1'b0;
      trap_dcfault_r    <= 1'b0;
      trap_misaligned_r <= 1'b0;
      aluRes_r          <= {XLEN{1'b0}};
      memData_r         <= {XLEN{1'b0}};
      csr_rdata_r       <= 64'h0;
      csr_wdata_r       <= 64'h0;
    end else if (flush_i) begin
      valid_r           <= 1'b0;
      regWr_r           <= 1'b0;
      trap_illegal_r    <= 1'b0;
      trap_icfault_r    <= 1'b0;
      trap_dcfault_r    <= 1'b0;
      trap_misaligned_r <= 1'b0;
    end else if (!global_stall_i) begin
      valid_r           <= ex_mem_valid_i;
      instr_r           <= ex_mem_instr_i;
      pc_r              <= ex_mem_pc_i;
      regWr_r           <= ex_mem_regWr_i;
      resultSrc_r       <= ex_mem_resultSrc_i;
      trap_illegal_r    <= ex_mem_trap_illegal_i;
      trap_icfault_r    <= ex_mem_trap_icfault_i;
      trap_dcfault_r    <= ex_mem_valid_i && ex_mem_dMemRd_i && (dc_err_buf_i || dc_err_i);
      trap_misaligned_r <= ex_mem_trap_misaligned_i;
      aluRes_r          <= ex_mem_aluRes_i;
      memData_r         <= dc_rdata_buf_valid_i ? dc_rdata_buf_i : dc_rdata_i;
      csr_rdata_r       <= ex_mem_csr_rdata_i;
      csr_wdata_r       <= ex_mem_csr_wdata_i;
    end
  end

endmodule : cc_mem_wb_reg
