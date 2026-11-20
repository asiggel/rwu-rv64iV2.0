// cc_ex_mem_reg.sv  –  RV_PipelineCacheFwd: EX/MEM pipeline register
//
//   flush_i        → kill control / trap flags (trap or mret in WB)
//   global_stall_i → hold
//   else           → load from EX stage
//
// flush_i is the WB-only flush (trap/mret), not the branch flush: a taken
// branch/JAL in EX must still reach WB to write its link register.
// flush_i overrides global_stall_i for the same reason as in cc_id_ex_reg.
`timescale 1ns/1ps

import as_pack::*;

module cc_ex_mem_reg (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    flush_i,
    input  logic                    global_stall_i,
    input  logic                    id_ex_valid_i,
    input  logic [instr_width-1:0]  id_ex_instr_i,
    input  logic [iaddr_width-1:0]  id_ex_pc_i,
    input  logic                    id_ex_regWr_i,
    input  logic                    id_ex_dMemRd_i,
    input  logic                    id_ex_dMemWr_i,
    input  result_src_t             id_ex_resultSrc_i,
    input  logic                    id_ex_trap_illegal_i,
    input  logic                    id_ex_trap_icfault_i,
    input  logic                    sys_illegal_i,
    input  logic                    misal_mem_i,
    input  logic                    misal_pc_i,
    input  logic [iaddr_width-1:0]  target_i,
    input  logic [reg_width-1:0]    aluRes_i,
    input  logic [reg_width-1:0]    csr_rdata_i,
    input  logic [reg_width-1:0]    csr_wdata_i,
    input  logic [63:0]             dc_wdata_i,
    input  logic [7:0]              dc_wstrb_i,
    output logic [instr_width-1:0]  instr_o,
    output logic [iaddr_width-1:0]  pc_o,
    output logic                    valid_o,
    output logic                    regWr_o,
    output logic                    dMemRd_o,
    output logic                    dMemWr_o,
    output result_src_t             resultSrc_o,
    output logic                    trap_illegal_o,
    output logic                    trap_icfault_o,
    output logic                    trap_misaligned_o,
    output logic [reg_width-1:0]    aluRes_o,
    output logic [reg_width-1:0]    csr_rdata_o,
    output logic [reg_width-1:0]    csr_wdata_o,
    output logic [63:0]             dc_wdata_o,
    output logic [7:0]              dc_wstrb_o
);

  localparam int XLEN = reg_width;
  localparam logic [instr_width-1:0] NOP_INSTR = 32'h00000013;

  logic [instr_width-1:0] instr_r;
  logic [iaddr_width-1:0] pc_r;
  logic                   valid_r;
  logic                   regWr_r;
  logic                   dMemRd_r;
  logic                   dMemWr_r;
  result_src_t            resultSrc_r;
  logic                   trap_illegal_r;
  logic                   trap_icfault_r;
  logic                   trap_misaligned_r;
  logic [reg_width-1:0]   aluRes_r;
  logic [reg_width-1:0]   csr_rdata_r;
  logic [reg_width-1:0]   csr_wdata_r;
  logic [63:0]            dc_wdata_r;
  logic [7:0]             dc_wstrb_r;

  assign instr_o           = instr_r;
  assign pc_o              = pc_r;
  assign valid_o           = valid_r;
  assign regWr_o           = regWr_r;
  assign dMemRd_o          = dMemRd_r;
  assign dMemWr_o          = dMemWr_r;
  assign resultSrc_o       = resultSrc_r;
  assign trap_illegal_o    = trap_illegal_r;
  assign trap_icfault_o    = trap_icfault_r;
  assign trap_misaligned_o = trap_misaligned_r;
  assign aluRes_o          = aluRes_r;
  assign csr_rdata_o       = csr_rdata_r;
  assign csr_wdata_o       = csr_wdata_r;
  assign dc_wdata_o        = dc_wdata_r;
  assign dc_wstrb_o        = dc_wstrb_r;

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      valid_r           <= 1'b0;
      instr_r           <= NOP_INSTR;
      pc_r              <= 64'h0;
      regWr_r           <= 1'b0;
      dMemRd_r          <= 1'b0;
      dMemWr_r          <= 1'b0;
      resultSrc_r       <= RES_ALU;
      trap_illegal_r    <= 1'b0;
      trap_icfault_r    <= 1'b0;
      trap_misaligned_r <= 1'b0;
      aluRes_r          <= {XLEN{1'b0}};
      csr_rdata_r       <= 64'h0;
      csr_wdata_r       <= 64'h0;
      dc_wdata_r        <= 64'h0;
      dc_wstrb_r        <= 8'h0;
    end else if (flush_i) begin
      valid_r           <= 1'b0;
      regWr_r           <= 1'b0;
      dMemRd_r          <= 1'b0;
      dMemWr_r          <= 1'b0;
      trap_illegal_r    <= 1'b0;
      trap_icfault_r    <= 1'b0;
      trap_misaligned_r <= 1'b0;
    end else if (!global_stall_i) begin
      valid_r           <= id_ex_valid_i;
      instr_r           <= id_ex_instr_i;
      pc_r              <= id_ex_pc_i;
      regWr_r           <= id_ex_regWr_i;
      dMemRd_r          <= id_ex_dMemRd_i;
      dMemWr_r          <= id_ex_dMemWr_i;
      resultSrc_r       <= id_ex_resultSrc_i;
      trap_illegal_r    <= id_ex_trap_illegal_i || (id_ex_valid_i && sys_illegal_i);
      trap_icfault_r    <= id_ex_trap_icfault_i;
      trap_misaligned_r <= id_ex_valid_i && (misal_mem_i || misal_pc_i);
      // A branch/jump never uses its ALU result; for a misaligned target the
      // slot carries the target to WB as mtval.
      aluRes_r          <= misal_pc_i ? target_i : aluRes_i;
      csr_rdata_r       <= csr_rdata_i;
      csr_wdata_r       <= csr_wdata_i;
      dc_wdata_r        <= dc_wdata_i;
      dc_wstrb_r        <= dc_wstrb_i;
    end
  end

endmodule : cc_ex_mem_reg
