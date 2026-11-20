// cc_id_ex_reg.sv  –  RV_PipelineCacheFwd: ID/EX pipeline register
//
//   flush_i         → bubble
//   global_stall_i  → hold
//   data_stall_i    → bubble (consumer stays in ID)
//   else            → load from ID stage
//
// flush_i overrides global_stall_i: a 1-cycle I-cache-hit lookup stall can
// coincide with the cycle a trap/mret retires in WB. Gating the squash
// behind the stall let stale wrong-path instructions survive the flush and
// commit once the stall cleared.
`timescale 1ns/1ps

import as_pack::*;

module cc_id_ex_reg (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    flush_i,
    input  logic                    global_stall_i,
    input  logic                    data_stall_i,
    input  logic                    if_id_valid_i,
    input  logic [instr_width-1:0]  if_id_instr_i,
    input  logic [iaddr_width-1:0]  if_id_pc_i,
    input  logic                    if_id_fault_i,
    input  logic                    regWr_i,
    input  logic                    dMemRd_i,
    input  logic                    dMemWr_i,
    input  logic                    aluSrcB_i,
    input  mux_a_t                  aluSrcA_i,
    input  result_src_t             resultSrc_i,
    input  alu_op_t                 aluOp_i,
    input  br_op_t                  brOp_i,
    input  logic                    jump_i,
    input  logic                    trap_illegal_i,
    input  logic [reg_width-1:0]    regA_i,
    input  logic [reg_width-1:0]    regB_i,
    input  logic [reg_width-1:0]    immExt_i,
    output logic [instr_width-1:0]  instr_o,
    output logic [iaddr_width-1:0]  pc_o,
    output logic                    valid_o,
    output logic                    regWr_o,
    output logic                    dMemRd_o,
    output logic                    dMemWr_o,
    output logic                    aluSrcB_o,
    output mux_a_t                  aluSrcA_o,
    output result_src_t             resultSrc_o,
    output alu_op_t                 aluOp_o,
    output br_op_t                  brOp_o,
    output logic                    jump_o,
    output logic                    trap_illegal_o,
    output logic                    trap_icfault_o,
    output logic [reg_width-1:0]    regA_o,
    output logic [reg_width-1:0]    regB_o,
    output logic [reg_width-1:0]    immExt_o
);

  localparam int XLEN = reg_width;
  localparam logic [instr_width-1:0] NOP_INSTR = 32'h00000013;

  logic [instr_width-1:0] instr_r;
  logic [iaddr_width-1:0] pc_r;
  logic                   valid_r;
  logic                   regWr_r;
  logic                   dMemRd_r;
  logic                   dMemWr_r;
  logic                   aluSrcB_r;
  mux_a_t                 aluSrcA_r;
  result_src_t            resultSrc_r;
  alu_op_t                aluOp_r;
  br_op_t                 brOp_r;
  logic                   jump_r;
  logic                   trap_illegal_r;
  logic                   trap_icfault_r;
  logic [reg_width-1:0]   regA_r;
  logic [reg_width-1:0]   regB_r;
  logic [reg_width-1:0]   immExt_r;

  assign instr_o        = instr_r;
  assign pc_o           = pc_r;
  assign valid_o        = valid_r;
  assign regWr_o        = regWr_r;
  assign dMemRd_o       = dMemRd_r;
  assign dMemWr_o       = dMemWr_r;
  assign aluSrcB_o      = aluSrcB_r;
  assign aluSrcA_o      = aluSrcA_r;
  assign resultSrc_o    = resultSrc_r;
  assign aluOp_o        = aluOp_r;
  assign brOp_o         = brOp_r;
  assign jump_o         = jump_r;
  assign trap_illegal_o = trap_illegal_r;
  assign trap_icfault_o = trap_icfault_r;
  assign regA_o         = regA_r;
  assign regB_o         = regB_r;
  assign immExt_o       = immExt_r;

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      valid_r        <= 1'b0;
      instr_r        <= NOP_INSTR;
      pc_r           <= 64'h0;
      regWr_r        <= 1'b0;
      dMemRd_r       <= 1'b0;
      dMemWr_r       <= 1'b0;
      aluSrcB_r      <= 1'b0;
      aluSrcA_r      <= SRC_REGA;
      resultSrc_r    <= RES_ALU;
      aluOp_r        <= ALU_ADD;
      brOp_r         <= BR_NONE;
      jump_r         <= 1'b0;
      trap_illegal_r <= 1'b0;
      trap_icfault_r <= 1'b0;
      regA_r         <= {XLEN{1'b0}};
      regB_r         <= {XLEN{1'b0}};
      immExt_r       <= {XLEN{1'b0}};
    end else if (flush_i || (!global_stall_i && data_stall_i)) begin
      valid_r        <= 1'b0;
      instr_r        <= NOP_INSTR;
      regWr_r        <= 1'b0;
      dMemRd_r       <= 1'b0;
      dMemWr_r       <= 1'b0;
      aluSrcB_r      <= 1'b0;
      aluSrcA_r      <= SRC_REGA;
      resultSrc_r    <= RES_ALU;
      aluOp_r        <= ALU_ADD;
      brOp_r         <= BR_NONE;
      jump_r         <= 1'b0;
      trap_illegal_r <= 1'b0;
      trap_icfault_r <= 1'b0;
      regA_r         <= {XLEN{1'b0}};
      regB_r         <= {XLEN{1'b0}};
      immExt_r       <= {XLEN{1'b0}};
    end else if (!global_stall_i) begin
      valid_r        <= if_id_valid_i;
      instr_r        <= if_id_instr_i;
      pc_r           <= if_id_pc_i;
      regWr_r        <= regWr_i  & if_id_valid_i;
      dMemRd_r       <= dMemRd_i & if_id_valid_i;
      dMemWr_r       <= dMemWr_i & if_id_valid_i;
      aluSrcB_r      <= aluSrcB_i;
      aluSrcA_r      <= aluSrcA_i;
      resultSrc_r    <= resultSrc_i;
      aluOp_r        <= aluOp_i;
      brOp_r         <= brOp_i;
      jump_r         <= jump_i;
      trap_illegal_r <= trap_illegal_i & if_id_valid_i;
      trap_icfault_r <= if_id_fault_i & if_id_valid_i;
      regA_r         <= regA_i;
      regB_r         <= regB_i;
      immExt_r       <= immExt_i;
    end
  end

endmodule : cc_id_ex_reg
