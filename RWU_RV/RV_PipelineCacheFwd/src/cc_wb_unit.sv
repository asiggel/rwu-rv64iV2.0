// cc_wb_unit.sv  –  RV_PipelineCacheFwd: write-back, commit and trap decision
//
// Contents:
//   result mux         ALU / load data / PC+4 / CSR read value
//   commit guard       an instruction commits exactly once, even if WB is
//                      held for several cycles by global_stall_i
//   trap decision      exception, interrupt or mret of the WB instruction
//   mcause / mtval     for cc_trap_csr
//   commit enables     register file, CSR write, instret
//
// Precise traps: an exception is taken on the WB instruction BEFORE it
// commits (no rd / CSR write, mepc = its own PC). An interrupt is taken the
// same way, except on a load/store: its memory access in MEM has already
// happened, so it commits and the interrupt is taken on the next
// instruction that reaches WB.
//
// ECALL/EBREAK and the I-cache/D-cache AXI4 fault traps need no early
// redirect here (unlike RV_NoPipeline): the I-cache uses a req/rvalid
// handshake with in-flight/discard bookkeeping (cc_fetch_unit), and the
// cache stalls release on ic_err/dc_err exactly like a normal completion.
`timescale 1ns/1ps

import as_pack::*;

module cc_wb_unit (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    global_stall_i,
    input  logic                    irq_pending_i,    // cc_trap_csr: enabled & pending
    input  logic                    is_csr_i,         // cc_hazard_unit: WB holds a CSR instr
    // ── MEM/WB register ──────────────────────────────────────────────────────
    input  logic                    valid_i,
    /* verilator lint_off UNUSEDSIGNAL */ // rd field [11:7] not needed here
    input  logic [instr_width-1:0]  instr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [iaddr_width-1:0]  pc_i,
    input  logic                    regWr_i,
    input  result_src_t             resultSrc_i,
    input  logic                    trap_illegal_i,
    input  logic                    trap_icfault_i,
    input  logic                    trap_dcfault_i,
    input  logic                    trap_misaligned_i,
    input  logic [reg_width-1:0]    aluRes_i,
    input  logic [reg_width-1:0]    memData_i,
    input  logic [reg_width-1:0]    csr_rdata_i,
    // ── Write-back ───────────────────────────────────────────────────────────
    output logic [reg_width-1:0]    result_o,
    output logic                    regWr_o,          // register file write enable
    output logic                    csr_we_o,
    output logic                    instret_o,
    output logic                    commit_o,
    // ── Trap / return ────────────────────────────────────────────────────────
    output logic                    exc_o,
    output logic [3:0]              exc_cause_o,
    output logic [63:0]             exc_tval_o,
    output logic                    irq_take_o,
    output logic                    trap_taken_o,     // exc_o | irq_take_o
    output logic                    mret_o
);

  localparam int XLEN = reg_width;

  logic                 committed_r;
  logic                 commit_s;
  logic                 exc_s;
  logic                 irq_take_s;
  logic                 trap_taken_s;
  logic                 is_mret_s;
  logic                 is_ecall_s;
  logic                 is_ebreak_s;
  logic                 is_mem_s;
  logic [reg_width-1:0] result_s;
  logic [3:0]           exc_cause_s;
  logic [63:0]          exc_tval_s;

  // ─── assign statements ───────────────────────────────────────────────────

  assign is_mret_s   = (instr_i[6:0] == 7'b1110011) && (instr_i[14:12] == 3'b000) &&
                       (instr_i[31:20] == 12'h302);
  assign is_ecall_s  = (instr_i[6:0] == 7'b1110011) && (instr_i[14:12] == 3'b000) &&
                       (instr_i[31:20] == 12'h000);
  assign is_ebreak_s = (instr_i[6:0] == 7'b1110011) && (instr_i[14:12] == 3'b000) &&
                       (instr_i[31:20] == 12'h001);
  assign is_mem_s    = (instr_i[6:0] == 7'b0000011) || (instr_i[6:0] == 7'b0100011);

  assign commit_s     = valid_i && !committed_r;
  assign exc_s        = commit_s &&
                        (trap_illegal_i || trap_misaligned_i ||
                         trap_icfault_i || trap_dcfault_i ||
                         is_ecall_s || is_ebreak_s);
  assign irq_take_s   = commit_s && irq_pending_i && !is_mem_s;
  assign trap_taken_s = exc_s || irq_take_s;

  assign result_o     = result_s;
  assign commit_o     = commit_s;
  assign exc_o        = exc_s;
  assign exc_cause_o  = exc_cause_s;
  assign exc_tval_o   = exc_tval_s;
  assign irq_take_o   = irq_take_s;
  assign trap_taken_o = trap_taken_s;
  assign mret_o       = commit_s && is_mret_s && !trap_taken_s;
  assign regWr_o      = regWr_i  && commit_s && !trap_taken_s;
  assign csr_we_o     = is_csr_i && commit_s && !trap_taken_s;
  assign instret_o    = commit_s && !trap_taken_s;

  // ─── always_comb blocks ──────────────────────────────────────────────────

  always_comb
    case (resultSrc_i)
      RES_ALU : result_s = aluRes_i;
      RES_MEM : result_s = memData_i;
      RES_PC4 : result_s = pc_i + 64'd4;
      RES_CSR : result_s = csr_rdata_i;
      default : result_s = {XLEN{1'b0}};
    endcase

  // For a misaligned branch/jump, aluRes_i holds the target (see
  // cc_ex_mem_reg); for loads/stores it is the access address.
  always_comb begin
    exc_cause_s = 4'd0;
    exc_tval_s  = 64'h0;
    if (trap_icfault_i) begin
      exc_cause_s = 4'd1;                 // instruction access fault
      exc_tval_s  = pc_i;
    end else if (trap_illegal_i) begin
      exc_cause_s = 4'd2;
      exc_tval_s  = {32'b0, instr_i};
    end else if (trap_misaligned_i) begin
      if      (instr_i[6:0] == 7'b0000011) exc_cause_s = 4'd4;
      else if (instr_i[6:0] == 7'b0100011) exc_cause_s = 4'd6;
      else                                 exc_cause_s = 4'd0;
      exc_tval_s  = aluRes_i;
    end else if (trap_dcfault_i) begin
      exc_cause_s = 4'd5;                 // load access fault
      exc_tval_s  = aluRes_i;
    end else if (is_ecall_s)
      exc_cause_s = 4'd11;
    else if (is_ebreak_s)
      exc_cause_s = 4'd3;
  end

  // ─── always_ff blocks ────────────────────────────────────────────────────

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      committed_r <= 1'b0;
    else if (!global_stall_i)
      committed_r <= 1'b0;
    else if (commit_s)
      committed_r <= 1'b1;
  end

endmodule : cc_wb_unit
