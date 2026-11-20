// cc_hazard_unit.sv  –  RV_PipelineCacheFwd: hazard detection, stall / flush
//                       generation and EX operand forwarding (purely combinational)
//
// Stall sources:
//   icache stall : no instruction ready (ibuf empty, no ic_rvalid / ic_err)
//   dcache stall : load in MEM waiting for dc_rvalid / dc_err
//   global stall : icache | dcache  – freezes all pipeline registers
//   data stall   : load-use or CSR hazard – freezes IF+ID, bubbles ID→EX
//
// Flush sources:
//   flush_front_o : branch taken in EX, or trap / mret in WB
//                   → squashes ibuf, IF/ID, ID/EX
//   flush_back_o  : trap / mret in WB only
//                   → squashes EX/MEM, MEM/WB and blocks dc_req.
//                   A taken branch is NOT included: the branch/JAL in EX must
//                   reach WB to commit its rd write (link register).
//
// Forwarding (RAW resolution without stall):
//   k=1  EX/MEM → EX  (non-load results only; load-use is stalled instead)
//   k=2  MEM/WB → EX  (any result, incl. load data, via wb_result_i)
//   k=3  handled outside by as_regfile WBR=1
//
// Both stalls release on err as well as on rvalid: an AXI4 fault must unblock
// the pipeline exactly like a normal completion, or the CPU would hang instead
// of trapping.
`timescale 1ns/1ps

import as_pack::*;

module cc_hazard_unit (
    // ── IF / fetch status ────────────────────────────────────────────────────
    input  logic                    ibuf_valid_i,
    input  logic                    ic_rvalid_i,
    input  logic                    ic_err_i,
    // ── ID stage ─────────────────────────────────────────────────────────────
    input  logic                    if_id_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */ // only opcode/funct3/register fields used
    input  logic [instr_width-1:0]  if_id_instr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    // ── EX stage ─────────────────────────────────────────────────────────────
    input  logic                    id_ex_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */ // only opcode/funct3/register fields used
    input  logic [instr_width-1:0]  id_ex_instr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                    id_ex_dMemRd_i,
    input  logic [reg_width-1:0]    id_ex_regA_i,
    input  logic [reg_width-1:0]    id_ex_regB_i,
    input  logic                    ex_take_i,
    input  logic                    ex_misal_pc_i,
    // ── MEM stage ────────────────────────────────────────────────────────────
    input  logic                    ex_mem_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */ // only opcode/funct3/register fields used
    input  logic [instr_width-1:0]  ex_mem_instr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [iaddr_width-1:0]  ex_mem_pc_i,
    input  logic                    ex_mem_regWr_i,
    input  logic                    ex_mem_dMemRd_i,
    input  logic                    ex_mem_trap_misaligned_i,
    input  result_src_t             ex_mem_resultSrc_i,
    input  logic [reg_width-1:0]    ex_mem_aluRes_i,
    input  logic [reg_width-1:0]    ex_mem_csr_rdata_i,
    input  logic                    dc_rvalid_i,
    input  logic                    dc_err_i,
    input  logic                    dc_rdata_buf_valid_i,
    input  logic                    dc_err_buf_i,
    // ── WB stage ─────────────────────────────────────────────────────────────
    input  logic                    mem_wb_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */ // only opcode/funct3/register fields used
    input  logic [instr_width-1:0]  mem_wb_instr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                    mem_wb_regWr_i,
    input  logic [reg_width-1:0]    wb_result_i,
    input  logic                    wb_trap_taken_i,
    input  logic                    wb_mret_i,
    // ── Stall / flush outputs ────────────────────────────────────────────────
    output logic                    dcache_stall_o,
    output logic                    global_stall_o,
    output logic                    data_stall_o,
    output logic                    branch_taken_o,
    output logic                    flush_front_o,
    output logic                    flush_back_o,
    output logic                    wb_is_csr_o,
    // ── Forwarded EX operands ────────────────────────────────────────────────
    output logic [reg_width-1:0]    fwd_srcA_o,
    output logic [reg_width-1:0]    fwd_srcB_o
);

  logic                 icache_stall_s;
  logic                 dcache_stall_s;
  logic                 global_stall_s;
  logic                 data_stall_s;

  logic [4:0]           id_rs1_s, id_rs2_s;
  logic [4:0]           ex_rs1_s, ex_rs2_s;
  logic [4:0]           ex_rd_s, mem_rd_s, wb_rd_s;
  logic                 id_is_csr_s, ex_is_csr_s, mem_is_csr_s, wb_is_csr_s;

  logic [reg_width-1:0] ex_mem_result_s;
  logic [reg_width-1:0] fwd_srcA_s;
  logic [reg_width-1:0] fwd_srcB_s;

  // ─── assign statements ───────────────────────────────────────────────────

  assign icache_stall_s = !ibuf_valid_i && !ic_rvalid_i && !ic_err_i;

  // A misaligned load sends no dc_req, so it must not wait for rvalid.
  assign dcache_stall_s = ex_mem_valid_i && ex_mem_dMemRd_i && !ex_mem_trap_misaligned_i
                          && !dc_rvalid_i && !dc_rdata_buf_valid_i
                          && !dc_err_i && !dc_err_buf_i;

  assign global_stall_s = icache_stall_s | dcache_stall_s;

  // A branch to a misaligned target traps in WB instead of redirecting.
  assign branch_taken_o = id_ex_valid_i && ex_take_i && !ex_misal_pc_i && !global_stall_s;
  assign flush_back_o   = wb_trap_taken_i | wb_mret_i;
  assign flush_front_o  = branch_taken_o | flush_back_o;

  assign id_rs1_s = if_id_instr_i[19:15];
  assign id_rs2_s = if_id_instr_i[24:20];
  assign ex_rs1_s = id_ex_instr_i[19:15];
  assign ex_rs2_s = id_ex_instr_i[24:20];
  assign ex_rd_s  = id_ex_instr_i[11:7];
  assign mem_rd_s = ex_mem_instr_i[11:7];
  assign wb_rd_s  = mem_wb_instr_i[11:7];

  // CSR instruction: opcode SYSTEM with funct3 != 000
  assign id_is_csr_s  = if_id_valid_i  && (if_id_instr_i[6:0]  == 7'b1110011) && (if_id_instr_i[14:12]  != 3'b000);
  assign ex_is_csr_s  = id_ex_valid_i  && (id_ex_instr_i[6:0]  == 7'b1110011) && (id_ex_instr_i[14:12]  != 3'b000);
  assign mem_is_csr_s = ex_mem_valid_i && (ex_mem_instr_i[6:0] == 7'b1110011) && (ex_mem_instr_i[14:12] != 3'b000);
  assign wb_is_csr_s  = mem_wb_valid_i && (mem_wb_instr_i[6:0] == 7'b1110011) && (mem_wb_instr_i[14:12] != 3'b000);

  assign dcache_stall_o = dcache_stall_s;
  assign global_stall_o = global_stall_s;
  assign data_stall_o   = data_stall_s;
  assign wb_is_csr_o    = wb_is_csr_s;
  assign fwd_srcA_o     = fwd_srcA_s;
  assign fwd_srcB_o     = fwd_srcB_s;

  // ─── always_comb blocks ──────────────────────────────────────────────────

  // Load data is not yet available in MEM; the load-use stall guarantees no
  // dependent instruction is in EX at that time, so loads need no case here.
  always_comb
    case (ex_mem_resultSrc_i)
      RES_PC4 : ex_mem_result_s = ex_mem_pc_i + 64'd4;
      RES_CSR : ex_mem_result_s = ex_mem_csr_rdata_i;
      default : ex_mem_result_s = ex_mem_aluRes_i;
    endcase

  // Only hazards forwarding cannot resolve:
  //   load-use : load result exists only at the end of MEM
  //   CSR      : CSR writes commit in WB and have no forwarding path
  always_comb begin
    data_stall_s = 1'b0;
    if (if_id_valid_i) begin
      if (id_ex_dMemRd_i && ex_rd_s != 5'b0 &&
          (ex_rd_s == id_rs1_s || ex_rd_s == id_rs2_s))
        data_stall_s = 1'b1;
      if (id_is_csr_s && (ex_is_csr_s || mem_is_csr_s || wb_is_csr_s))
        data_stall_s = 1'b1;
    end
  end

  // EX/MEM has priority over MEM/WB: it holds the younger (newer) value.
  always_comb begin
    fwd_srcA_s = id_ex_regA_i;
    if (ex_mem_regWr_i && !ex_mem_dMemRd_i &&
        mem_rd_s != 5'b0 && mem_rd_s == ex_rs1_s)
      fwd_srcA_s = ex_mem_result_s;
    else if (mem_wb_regWr_i &&
             wb_rd_s != 5'b0 && wb_rd_s == ex_rs1_s)
      fwd_srcA_s = wb_result_i;
  end

  always_comb begin
    fwd_srcB_s = id_ex_regB_i;
    if (ex_mem_regWr_i && !ex_mem_dMemRd_i &&
        mem_rd_s != 5'b0 && mem_rd_s == ex_rs2_s)
      fwd_srcB_s = ex_mem_result_s;
    else if (mem_wb_regWr_i &&
             wb_rd_s != 5'b0 && wb_rd_s == ex_rs2_s)
      fwd_srcB_s = wb_result_i;
  end

endmodule : cc_hazard_unit
