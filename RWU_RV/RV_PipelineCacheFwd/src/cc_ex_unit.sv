// cc_ex_unit.sv  –  RV_PipelineCacheFwd: execute (EX stage)
//
// Contents:
//   operand muxes      srcA: forwarded rs1 / PC / zero, srcB: forwarded rs2 / imm
//   ALU, branch ALU    as_alu, as_alu_branch (shared with RV_NoPipeline)
//   branch target      PC + imm (branches, JAL) or rs1 + imm (JALR)
//   misaligned checks  taken branch/jump target, load/store address
//   CSR write value    forwarded rs1 or uimm5
//   store data         replicated rs2 + byte strobes for the D-cache
//
// All register operands arrive already forwarded (cc_hazard_unit), so every
// consumer of rs1/rs2 in EX sees the newest value.
`timescale 1ns/1ps

import as_pack::*;

module cc_ex_unit (
    // ── ID/EX register ───────────────────────────────────────────────────────
    /* verilator lint_off UNUSEDSIGNAL */ // only funct3 and the uimm5/rs1 field are used
    input  logic [instr_width-1:0]  instr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [iaddr_width-1:0]  pc_i,
    input  logic                    dMemRd_i,
    input  logic                    dMemWr_i,
    input  logic                    aluSrcB_i,
    input  mux_a_t                  aluSrcA_i,
    input  alu_op_t                 aluOp_i,
    input  br_op_t                  brOp_i,
    input  logic                    jump_i,
    input  logic [reg_width-1:0]    immExt_i,
    // ── Forwarded register operands (cc_hazard_unit) ─────────────────────────
    input  logic [reg_width-1:0]    rs1_i,
    input  logic [reg_width-1:0]    rs2_i,
    // ── Results ──────────────────────────────────────────────────────────────
    output logic [reg_width-1:0]    aluRes_o,
    output logic                    take_o,         // branch condition / jump
    output logic [iaddr_width-1:0]  target_o,       // JALR bit 0 cleared
    output logic                    misal_pc_o,     // taken branch/jump to a non-word address
    output logic                    misal_mem_o,    // misaligned load/store address
    output logic [reg_width-1:0]    csr_wdata_o,
    output logic [63:0]             dc_wdata_o,
    output logic [7:0]              dc_wstrb_o
);

  localparam int XLEN = reg_width;

  logic [reg_width-1:0]   srcA_s;
  logic [reg_width-1:0]   srcB_s;
  logic [reg_width-1:0]   aluRes_s;
  logic                   take_s;
  logic [iaddr_width-1:0] PCorRS1_s;
  logic [iaddr_width-1:0] PCbr_s;
  logic [iaddr_width-1:0] target_s;
  logic                   misal_mem_s;
  logic [reg_width-1:0]   csr_wdata_s;
  logic [63:0]            dc_wdata_s;
  logic [7:0]             dc_wstrb_s;

  // ─── assign statements ───────────────────────────────────────────────────

  assign srcB_s    = aluSrcB_i ? immExt_i : rs2_i;
  assign PCorRS1_s = jump_i    ? rs1_i    : pc_i;
  assign PCbr_s    = PCorRS1_s + immExt_i;
  // JALR clears bit 0 of its target; with IALIGN = 32 bit 1 must then be 0.
  assign target_s  = jump_i ? {PCbr_s[iaddr_width-1:1], 1'b0} : PCbr_s;

  assign aluRes_o    = aluRes_s;
  assign take_o      = take_s;
  assign target_o    = target_s;
  assign misal_pc_o  = take_s && (target_s[1:0] != 2'b00);
  assign misal_mem_o = misal_mem_s;
  assign csr_wdata_o = csr_wdata_s;
  assign dc_wdata_o  = dc_wdata_s;
  assign dc_wstrb_o  = dc_wstrb_s;

  // ─── always_comb blocks ──────────────────────────────────────────────────

  always_comb
    case (aluSrcA_i)
      SRC_REGA : srcA_s = rs1_i;
      SRC_PC   : srcA_s = pc_i;
      SRC_ZERO : srcA_s = {XLEN{1'b0}};
      default  : srcA_s = rs1_i;
    endcase

  // funct3[1:0] = access size B, H, W, D
  always_comb begin
    misal_mem_s = 1'b0;
    if (dMemRd_i || dMemWr_i)
      case (instr_i[13:12])
        2'b01:   misal_mem_s = aluRes_s[0];
        2'b10:   misal_mem_s = (aluRes_s[1:0] != 2'b00);
        2'b11:   misal_mem_s = (aluRes_s[2:0] != 3'b000);
        default: misal_mem_s = 1'b0;
      endcase
  end

  // funct3[2]=1: CSRRWI/CSRRSI/CSRRCI use uimm5 from instr[19:15]
  always_comb begin
    if (instr_i[14])
      csr_wdata_s = {{(XLEN-5){1'b0}}, instr_i[19:15]};
    else
      csr_wdata_s = rs1_i;
  end

  always_comb begin
    dc_wdata_s = rs2_i;
    dc_wstrb_s = 8'hFF;
    if (dMemWr_i)
      case (instr_i[14:12])
        3'b000: begin
          dc_wdata_s = {8{rs2_i[7:0]}};
          dc_wstrb_s = 8'h01 << aluRes_s[2:0];
        end
        3'b001: begin
          dc_wdata_s = {4{rs2_i[15:0]}};
          dc_wstrb_s = 8'h03 << {aluRes_s[2:1], 1'b0};
        end
        3'b010: begin
          dc_wdata_s = {2{rs2_i[31:0]}};
          dc_wstrb_s = 8'h0F << {aluRes_s[2], 2'b0};
        end
        default:;
      endcase
  end

  // ─── module instantiations ───────────────────────────────────────────────

  as_alu alua (
    .data01_i   (srcA_s),
    .data02_i   (srcB_s),
    .alu_op_i   (aluOp_i),
    .aluResult_o(aluRes_s)
  );

  as_alu_branch alub (
    .data01_i(srcA_s),
    .data02_i(srcB_s),
    .br_op_i (brOp_i),
    .take_o  (take_s)
  );

endmodule : cc_ex_unit
