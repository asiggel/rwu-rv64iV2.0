// cc_id_unit.sv  –  RV_PipelineCacheFwd: instruction decode (ID stage)
//
// Contents:
//   control decoder    as_instr_decode (shared with RV_NoPipeline)
//   immediate          sign-extended I/S/B/J/U immediate
//
// The register file is read in ID but written in WB, so it stays in the
// core (cc_cpupipefwd) next to cc_trap_csr, which has the same EX-read /
// WB-write split.
`timescale 1ns/1ps

import as_pack::*;

module cc_id_unit (
    input  logic [instr_width-1:0]  instr_i,
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
    output logic [reg_width-1:0]    immExt_o
);

  localparam int XLEN = reg_width;

  imm_src_t             immSrc_s;
  logic [reg_width-1:0] immExt_s;

  // ─── assign statements ───────────────────────────────────────────────────

  assign immExt_o = immExt_s;

  // ─── always_comb blocks ──────────────────────────────────────────────────

  always_comb
    case (immSrc_s)
      IMM_I   : immExt_s = {{(XLEN-12){instr_i[31]}}, instr_i[31:20]};
      IMM_S   : immExt_s = {{(XLEN-12){instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
      IMM_B   : immExt_s = {{(XLEN-12){instr_i[31]}}, instr_i[7], instr_i[30:25],
                            instr_i[11:8], 1'b0};
      IMM_J   : immExt_s = {{(XLEN-20){instr_i[31]}}, instr_i[19:12], instr_i[20],
                            instr_i[30:21], 1'b0};
      IMM_U   : immExt_s = {{(XLEN-32){instr_i[31]}}, instr_i[31:12], 12'b0};
      default : immExt_s = {XLEN{1'b0}};
    endcase

  // ─── module instantiations ───────────────────────────────────────────────

  as_instr_decode control (
    .instr_opcode_i      (instr_i[6:0]),
    .instr_func3_i       (instr_i[14:12]),
    .instr_func7b5_i     (instr_i[30]),
    .take_i              (1'b0),
    .mux_resultSrc_o     (resultSrc_o),
    .en_dMemWr_o         (dMemWr_o),
    .en_dMemRd_o         (dMemRd_o),
    .mux_aluSrcB_o       (aluSrcB_o),
    .mux_aluSrcA_o       (aluSrcA_o),
    .en_regWr_o          (regWr_o),
    .mux_jump_o          (jump_o),
    .sel_immSrc_o        (immSrc_s),
    .alu_op_o            (aluOp_o),
    .br_op_o             (brOp_o),
    .trap_illegal_instr_o(trap_illegal_o)
  );

endmodule : cc_id_unit
