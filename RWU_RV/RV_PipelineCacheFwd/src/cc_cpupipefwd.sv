// cc_cpupipefwd.sv  –  RV_PipelineCacheFwd: 5-stage pipeline with forwarding
//
// Based on cc_cpupipe (stall-only, RV_PipelineCache) with the following upgrade:
//
//   EX/MEM → EX  forwarding  (1-back ALU result):
//     When the instruction in MEM writes a register that the instruction in EX
//     reads, the ALU result (or PC+4 / CSR rdata) stored in ex_mem_aluRes_r /
//     ex_mem_csr_rdata_r / ex_mem_pc_r is fed directly to the EX input mux,
//     bypassing the stale value that was latched in id_ex_regA/B_r.
//
//   MEM/WB → EX  forwarding  (2-back, any result including load data):
//     When the instruction in WB writes a register that the instruction in EX
//     reads, the final result wb_result_s (which already muxes ALU / load data
//     / PC+4 / CSR) is forwarded to the EX input mux.
//
// Remaining stall sources (hazards forwarding cannot resolve):
//
//   Load-use  (1 cycle):
//     A LOAD is in EX (id_ex_dMemRd_r = 1).  The load result is produced at
//     the END of the following MEM stage; it cannot be forwarded to a consumer
//     also in EX at the same time.  The pipeline inserts one bubble: the
//     consumer stays in ID, a NOP enters EX.  In the next cycle the LOAD is in
//     WB and the consumer is in EX → MEM/WB → EX forwarding resolves it.
//
//   k=3 RAW — handled transparently by as_regfile WBR=1:
//     When A is in WB and B is in ID, both events happen at the same posedge.
//     as_regfile instantiated with WBR=1 bypasses wdata01_i combinatorially to
//     rdata_o in the active region, so id_ex_regA/B_r captures A's new value
//     without a pipeline stall.
//
//   CSR hazard  (conservative stall, unchanged from cc_cpupipe):
//     CSR writes commit at WB.  No forwarding path exists from WB back to EX
//     for CSR register values.  Any CSR instruction in ID is held until the
//     pipeline contains no earlier CSR instructions.
//
// Interface, cache handling, branch:  identical to cc_cpupipe.
//
// Submodules:
//   cc_fetch_unit   IF stage: PC, I-cache handshake, instruction buffer
//   cc_id_unit      ID stage: control decoder, immediate
//   cc_ex_unit      EX stage: operand muxes, ALUs, branch target, store data
//   cc_mem_unit     MEM stage: D-cache request, read-data / error buffer
//   cc_wb_unit      WB stage: result mux, commit, trap/mret decision
//   cc_if_id_reg, cc_id_ex_reg, cc_ex_mem_reg, cc_mem_wb_reg
//                   the four pipeline registers
//   cc_hazard_unit  hazard detection, stall/flush generation, forwarding
// The *_r names of their register outputs are kept here so testbench
// hierarchy paths (PC_r, if_id_instr_r, mem_wb_pc_r, ...) stay valid.
//
// Traps / IRQ (cc_trap_csr holds all M-mode CSRs):
//   Exceptions are detected up to EX/MEM and carried as flags to WB, where
//   the trap is taken with mepc = PC of the faulting instruction. A load or
//   store that carries an exception never sends dc_req, and no younger
//   instruction in MEM sends dc_req in the cycle WB traps -- so a trapping or
//   squashed instruction leaves memory untouched.
//   An interrupt is taken on the instruction in WB BEFORE it commits
//   (squashed, mepc = its own PC), except for a load/store: its memory access
//   in MEM has already happened, so it commits and the interrupt is taken on
//   the next instruction that reaches WB.
//   WFI is executed as a NOP (allowed by the privileged spec).
`timescale 1ns/1ps

import as_pack::*;

module cc_cpupipefwd #(parameter logic [63:0] HART_ID = 64'd0) (
    input  logic                           clk_i,
    input  logic                           rst_i,
    input  logic                           tck_i,
    output logic [instr_width-1:0]         ir_o,
    input  logic                           dr_cap_i,
    output logic                           sc01_tdo_o,
    input  logic                           sc01_tdi_i,
    input  logic                           sc01_shift_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                           sc01_clock_i,
    /* verilator lint_on UNUSEDSIGNAL */
    as_icache_if.cpu                       icpu_if,
    as_dcache_if.cpu                       dcpu_if,
    /* verilator lint_off UNUSEDSIGNAL */ // only bit 7 (ICU output -> mip.MEIP) implemented
    input  logic [irq_total_num_ext_c-1:0] irq_ext_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                           irq_m_soft_i,   // CLINT msip -> mip.MSIP
    input  logic                           irq_m_timer_i   // CLINT mtip -> mip.MTIP
);

  // ─── 1. ALL signal declarations ───────────────────────────────────────────

  // ── Stall / flush (cc_hazard_unit) ─────────────────────────────────────────
  logic dcache_stall_s;   // DC load is waiting for rvalid
  logic global_stall_s;   // icache | dcache stall – freezes all stages
  logic data_stall_s;     // load-use or CSR hazard: freezes IF+ID, bubbles ID→EX
  logic flush_s;          // branch taken (EX) or trap/mret (WB): IF, ID, EX
  logic flush_back_s;     // trap/mret (WB) only: MEM, WB, dc_req

  // ── IF stage (cc_fetch_unit outputs) ──────────────────────────────────────
  logic [iaddr_width-1:0] PC_r;
  logic [iaddr_width-1:0] fetch_pc_r;
  logic [instr_width-1:0] ibuf_instr_r;
  logic [iaddr_width-1:0] ibuf_pc_r;
  logic                   ibuf_valid_r;
  logic                   ibuf_fault_r;   // buffered fetch was an AXI4/I-cache error (ic_err), not a real instruction
  logic                   if_id_advance_s;

  // ── IF/ID pipeline register (cc_if_id_reg outputs) ─────────────────────────
  logic [instr_width-1:0] if_id_instr_r;
  logic [iaddr_width-1:0] if_id_pc_r;
  logic                   if_id_valid_r;
  logic                   if_id_fault_r;  // this slot is a synthetic NOP standing in for an I-cache fault

  // ── ID stage (cc_id_unit outputs) ──────────────────────────────────────────
  logic                   id_regWr_s;
  logic                   id_dMemRd_s;
  logic                   id_dMemWr_s;
  logic                   id_aluSrcB_s;
  mux_a_t                 id_aluSrcA_s;
  result_src_t            id_resultSrc_s;
  alu_op_t                id_aluOp_s;
  br_op_t                 id_brOp_s;
  logic                   id_jump_s;
  logic                   id_trap_illegal_s;
  logic [reg_width-1:0]   id_immExt_s;

  // ── ID/EX pipeline register (cc_id_ex_reg outputs) ──────────────────────────
  logic [instr_width-1:0] id_ex_instr_r;
  logic [iaddr_width-1:0] id_ex_pc_r;
  logic                   id_ex_valid_r;
  logic                   id_ex_regWr_r;
  logic                   id_ex_dMemRd_r;
  logic                   id_ex_dMemWr_r;
  logic                   id_ex_aluSrcB_r;
  mux_a_t                 id_ex_aluSrcA_r;
  result_src_t            id_ex_resultSrc_r;
  alu_op_t                id_ex_aluOp_r;
  br_op_t                 id_ex_brOp_r;
  logic                   id_ex_jump_r;
  logic                   id_ex_trap_illegal_r;
  logic                   id_ex_trap_icfault_r;
  logic [reg_width-1:0]   id_ex_regA_r;
  logic [reg_width-1:0]   id_ex_regB_r;
  logic [reg_width-1:0]   id_ex_immExt_r;

  // ── EX stage (cc_ex_unit outputs, cc_trap_csr read port) ───────────────────
  logic [reg_width-1:0]   ex_aluRes_s;
  logic                   ex_take_s;
  logic [reg_width-1:0]   ex_csr_rdata_s;
  logic [reg_width-1:0]   ex_csr_wdata_s;
  logic [63:0]            ex_dc_wdata_s;
  logic [7:0]             ex_dc_wstrb_s;
  logic                   ex_branch_taken_s;
  logic [iaddr_width-1:0] ex_target_s;      // branch/jump target, JALR bit 0 cleared
  logic                   ex_misal_pc_s;    // taken branch/jump to a non-word address
  logic                   ex_misal_mem_s;   // misaligned load/store address
  logic                   ex_sys_illegal_s; // illegal SYSTEM instruction (cc_trap_csr)

  // ── EX/MEM pipeline register (cc_ex_mem_reg outputs) ───────────────────────
  logic [instr_width-1:0] ex_mem_instr_r;
  logic [iaddr_width-1:0] ex_mem_pc_r;
  logic                   ex_mem_valid_r;
  logic                   ex_mem_regWr_r;
  logic                   ex_mem_dMemRd_r;
  logic                   ex_mem_dMemWr_r;
  result_src_t            ex_mem_resultSrc_r;
  logic                   ex_mem_trap_illegal_r;
  logic                   ex_mem_trap_icfault_r;
  logic                   ex_mem_trap_misaligned_r;
  logic [reg_width-1:0]   ex_mem_aluRes_r;
  logic [reg_width-1:0]   ex_mem_csr_rdata_r;
  logic [reg_width-1:0]   ex_mem_csr_wdata_r;
  logic [63:0]            ex_mem_dc_wdata_r;
  logic [7:0]             ex_mem_dc_wstrb_r;

  // ── MEM stage (cc_mem_unit outputs) ────────────────────────────────────────
  logic [reg_width-1:0]   dc_rdata_buf_r;
  logic                   dc_rdata_buf_valid_r;
  logic                   dc_err_buf_r;    // dc_err arrived while global_stall_s was still held by another cause

  // ── MEM/WB pipeline register (cc_mem_wb_reg outputs) ───────────────────────
  logic [instr_width-1:0] mem_wb_instr_r;
  logic [iaddr_width-1:0] mem_wb_pc_r;
  logic                   mem_wb_valid_r;
  logic                   mem_wb_regWr_r;
  result_src_t            mem_wb_resultSrc_r;
  logic                   mem_wb_trap_illegal_r;
  logic                   mem_wb_trap_icfault_r;  // I-cache AXI4 error on the fetch of this slot
  logic                   mem_wb_trap_dcfault_r;  // D-cache AXI4 error on this slot's load
  logic                   mem_wb_trap_misaligned_r;
  logic [reg_width-1:0]   mem_wb_aluRes_r;
  logic [reg_width-1:0]   mem_wb_memData_r;
  logic [reg_width-1:0]   mem_wb_csr_rdata_r;
  logic [reg_width-1:0]   mem_wb_csr_wdata_r;

  // ── WB stage (cc_wb_unit outputs) ──────────────────────────────────────────
  logic [reg_width-1:0]   wb_result_s;
  logic                   wb_regWr_final_s;
  logic                   wb_commit_s;
  logic                   wb_trap_taken_s;
  logic                   wb_exc_s;
  logic                   wb_irq_take_s;
  logic                   wb_mret_s;
  logic [3:0]             wb_exc_cause_s;
  logic [63:0]            wb_exc_tval_s;

  // ── Register file ──────────────────────────────────────────────────────────
  logic [reg_width-1:0] rf_rdata1_s, rf_rdata2_s;

  // ── Trap / CSR unit ────────────────────────────────────────────────────────
  logic        irq_pending_s;
  logic        csr_we_s;
  logic        instret_s;
  logic [63:0] trap_vec_s;
  logic [63:0] mepc_s;


  // ── Hazard unit outputs ────────────────────────────────────────────────────
  logic                 wb_is_csr_s;
  logic [reg_width-1:0] fwd_srcA_s;
  logic [reg_width-1:0] fwd_srcB_s;

  // ── Scan chain ─────────────────────────────────────────────────────────────
  logic and_in01_s, sc01_01_s, sc01_02_s, sc01_03_s;
  logic and_in02_s, and_out_s;
  logic gated_clk_s, clk_mux_s;

  // ─── 2. assign statements ─────────────────────────────────────────────────

  assign icpu_if.ic_flush = 1'b0;
  assign dcpu_if.dc_flush = 1'b0;

  assign ir_o = mem_wb_instr_r;

  // ─── 3. Module instantiations ──────────────────────────────────────────────

  cc_fetch_unit fetch (
    .clk_i          (clk_i),
    .rst_i          (rst_i),
    .flush_i        (flush_s),
    .data_stall_i   (data_stall_s),
    .dcache_stall_i (dcache_stall_s),
    .trap_taken_i   (wb_trap_taken_s),
    .trap_vec_i     (trap_vec_s),
    .mret_i         (wb_mret_s),
    .mepc_i         (mepc_s),
    .branch_taken_i (ex_branch_taken_s),
    .branch_target_i(ex_target_s),
    .ic_req_o       (icpu_if.ic_req),
    .ic_addr_o      (icpu_if.ic_addr),
    .ic_rvalid_i    (icpu_if.ic_rvalid),
    .ic_err_i       (icpu_if.ic_err),
    .ic_rdata_i     (icpu_if.ic_rdata),
    .pc_o           (PC_r),
    .fetch_pc_o     (fetch_pc_r),
    .ibuf_valid_o   (ibuf_valid_r),
    .ibuf_instr_o   (ibuf_instr_r),
    .ibuf_pc_o      (ibuf_pc_r),
    .ibuf_fault_o   (ibuf_fault_r),
    .if_id_advance_o(if_id_advance_s)
  );

  cc_if_id_reg if_id (
    .clk_i       (clk_i),
    .rst_i       (rst_i),
    .flush_i     (flush_s),
    .advance_i   (if_id_advance_s),
    .ibuf_valid_i(ibuf_valid_r),
    .ibuf_instr_i(ibuf_instr_r),
    .ibuf_pc_i   (ibuf_pc_r),
    .ibuf_fault_i(ibuf_fault_r),
    .ic_rdata_i  (icpu_if.ic_rdata),
    .ic_err_i    (icpu_if.ic_err),
    .fetch_pc_i  (fetch_pc_r),
    .instr_o     (if_id_instr_r),
    .pc_o        (if_id_pc_r),
    .valid_o     (if_id_valid_r),
    .fault_o     (if_id_fault_r)
  );

  cc_id_ex_reg id_ex (
    .clk_i         (clk_i),
    .rst_i         (rst_i),
    .flush_i       (flush_s),
    .global_stall_i(global_stall_s),
    .data_stall_i  (data_stall_s),
    .if_id_valid_i (if_id_valid_r),
    .if_id_instr_i (if_id_instr_r),
    .if_id_pc_i    (if_id_pc_r),
    .if_id_fault_i (if_id_fault_r),
    .regWr_i       (id_regWr_s),
    .dMemRd_i      (id_dMemRd_s),
    .dMemWr_i      (id_dMemWr_s),
    .aluSrcB_i     (id_aluSrcB_s),
    .aluSrcA_i     (id_aluSrcA_s),
    .resultSrc_i   (id_resultSrc_s),
    .aluOp_i       (id_aluOp_s),
    .brOp_i        (id_brOp_s),
    .jump_i        (id_jump_s),
    .trap_illegal_i(id_trap_illegal_s),
    .regA_i        (rf_rdata1_s),
    .regB_i        (rf_rdata2_s),
    .immExt_i      (id_immExt_s),
    .instr_o       (id_ex_instr_r),
    .pc_o          (id_ex_pc_r),
    .valid_o       (id_ex_valid_r),
    .regWr_o       (id_ex_regWr_r),
    .dMemRd_o      (id_ex_dMemRd_r),
    .dMemWr_o      (id_ex_dMemWr_r),
    .aluSrcB_o     (id_ex_aluSrcB_r),
    .aluSrcA_o     (id_ex_aluSrcA_r),
    .resultSrc_o   (id_ex_resultSrc_r),
    .aluOp_o       (id_ex_aluOp_r),
    .brOp_o        (id_ex_brOp_r),
    .jump_o        (id_ex_jump_r),
    .trap_illegal_o(id_ex_trap_illegal_r),
    .trap_icfault_o(id_ex_trap_icfault_r),
    .regA_o        (id_ex_regA_r),
    .regB_o        (id_ex_regB_r),
    .immExt_o      (id_ex_immExt_r)
  );

  cc_ex_mem_reg ex_mem (
    .clk_i               (clk_i),
    .rst_i               (rst_i),
    .flush_i             (flush_back_s),
    .global_stall_i      (global_stall_s),
    .id_ex_valid_i       (id_ex_valid_r),
    .id_ex_instr_i       (id_ex_instr_r),
    .id_ex_pc_i          (id_ex_pc_r),
    .id_ex_regWr_i       (id_ex_regWr_r),
    .id_ex_dMemRd_i      (id_ex_dMemRd_r),
    .id_ex_dMemWr_i      (id_ex_dMemWr_r),
    .id_ex_resultSrc_i   (id_ex_resultSrc_r),
    .id_ex_trap_illegal_i(id_ex_trap_illegal_r),
    .id_ex_trap_icfault_i(id_ex_trap_icfault_r),
    .sys_illegal_i       (ex_sys_illegal_s),
    .misal_mem_i         (ex_misal_mem_s),
    .misal_pc_i          (ex_misal_pc_s),
    .target_i            (ex_target_s),
    .aluRes_i            (ex_aluRes_s),
    .csr_rdata_i         (ex_csr_rdata_s),
    .csr_wdata_i         (ex_csr_wdata_s),
    .dc_wdata_i          (ex_dc_wdata_s),
    .dc_wstrb_i          (ex_dc_wstrb_s),
    .instr_o             (ex_mem_instr_r),
    .pc_o                (ex_mem_pc_r),
    .valid_o             (ex_mem_valid_r),
    .regWr_o             (ex_mem_regWr_r),
    .dMemRd_o            (ex_mem_dMemRd_r),
    .dMemWr_o            (ex_mem_dMemWr_r),
    .resultSrc_o         (ex_mem_resultSrc_r),
    .trap_illegal_o      (ex_mem_trap_illegal_r),
    .trap_icfault_o      (ex_mem_trap_icfault_r),
    .trap_misaligned_o   (ex_mem_trap_misaligned_r),
    .aluRes_o            (ex_mem_aluRes_r),
    .csr_rdata_o         (ex_mem_csr_rdata_r),
    .csr_wdata_o         (ex_mem_csr_wdata_r),
    .dc_wdata_o          (ex_mem_dc_wdata_r),
    .dc_wstrb_o          (ex_mem_dc_wstrb_r)
  );

  cc_mem_wb_reg mem_wb (
    .clk_i                   (clk_i),
    .rst_i                   (rst_i),
    .flush_i                 (flush_back_s),
    .global_stall_i          (global_stall_s),
    .ex_mem_valid_i          (ex_mem_valid_r),
    .ex_mem_instr_i          (ex_mem_instr_r),
    .ex_mem_pc_i             (ex_mem_pc_r),
    .ex_mem_regWr_i          (ex_mem_regWr_r),
    .ex_mem_dMemRd_i         (ex_mem_dMemRd_r),
    .ex_mem_resultSrc_i      (ex_mem_resultSrc_r),
    .ex_mem_trap_illegal_i   (ex_mem_trap_illegal_r),
    .ex_mem_trap_icfault_i   (ex_mem_trap_icfault_r),
    .ex_mem_trap_misaligned_i(ex_mem_trap_misaligned_r),
    .ex_mem_aluRes_i         (ex_mem_aluRes_r),
    .ex_mem_csr_rdata_i      (ex_mem_csr_rdata_r),
    .ex_mem_csr_wdata_i      (ex_mem_csr_wdata_r),
    .dc_rdata_i              (dcpu_if.dc_rdata),
    .dc_err_i                (dcpu_if.dc_err),
    .dc_rdata_buf_i          (dc_rdata_buf_r),
    .dc_rdata_buf_valid_i    (dc_rdata_buf_valid_r),
    .dc_err_buf_i            (dc_err_buf_r),
    .instr_o                 (mem_wb_instr_r),
    .pc_o                    (mem_wb_pc_r),
    .valid_o                 (mem_wb_valid_r),
    .regWr_o                 (mem_wb_regWr_r),
    .resultSrc_o             (mem_wb_resultSrc_r),
    .trap_illegal_o          (mem_wb_trap_illegal_r),
    .trap_icfault_o          (mem_wb_trap_icfault_r),
    .trap_dcfault_o          (mem_wb_trap_dcfault_r),
    .trap_misaligned_o       (mem_wb_trap_misaligned_r),
    .aluRes_o                (mem_wb_aluRes_r),
    .memData_o               (mem_wb_memData_r),
    .csr_rdata_o             (mem_wb_csr_rdata_r),
    .csr_wdata_o             (mem_wb_csr_wdata_r)
  );

  cc_id_unit id (
    .instr_i       (if_id_instr_r),
    .regWr_o       (id_regWr_s),
    .dMemRd_o      (id_dMemRd_s),
    .dMemWr_o      (id_dMemWr_s),
    .aluSrcB_o     (id_aluSrcB_s),
    .aluSrcA_o     (id_aluSrcA_s),
    .resultSrc_o   (id_resultSrc_s),
    .aluOp_o       (id_aluOp_s),
    .brOp_o        (id_brOp_s),
    .jump_o        (id_jump_s),
    .trap_illegal_o(id_trap_illegal_s),
    .immExt_o      (id_immExt_s)
  );

  cc_ex_unit ex (
    .instr_i    (id_ex_instr_r),
    .pc_i       (id_ex_pc_r),
    .dMemRd_i   (id_ex_dMemRd_r),
    .dMemWr_i   (id_ex_dMemWr_r),
    .aluSrcB_i  (id_ex_aluSrcB_r),
    .aluSrcA_i  (id_ex_aluSrcA_r),
    .aluOp_i    (id_ex_aluOp_r),
    .brOp_i     (id_ex_brOp_r),
    .jump_i     (id_ex_jump_r),
    .immExt_i   (id_ex_immExt_r),
    .rs1_i      (fwd_srcA_s),
    .rs2_i      (fwd_srcB_s),
    .aluRes_o   (ex_aluRes_s),
    .take_o     (ex_take_s),
    .target_o   (ex_target_s),
    .misal_pc_o (ex_misal_pc_s),
    .misal_mem_o(ex_misal_mem_s),
    .csr_wdata_o(ex_csr_wdata_s),
    .dc_wdata_o (ex_dc_wdata_s),
    .dc_wstrb_o (ex_dc_wstrb_s)
  );

  cc_mem_unit mem (
    .clk_i            (clk_i),
    .rst_i            (rst_i),
    .global_stall_i   (global_stall_s),
    .flush_back_i     (flush_back_s),
    .valid_i          (ex_mem_valid_r),
    .dMemRd_i         (ex_mem_dMemRd_r),
    .dMemWr_i         (ex_mem_dMemWr_r),
    .trap_misaligned_i(ex_mem_trap_misaligned_r),
    .funct3_i         (ex_mem_instr_r[14:12]),
    .addr_i           (ex_mem_aluRes_r),
    .wdata_i          (ex_mem_dc_wdata_r),
    .wstrb_i          (ex_mem_dc_wstrb_r),
    .dc_req_o         (dcpu_if.dc_req),
    .dc_wr_o          (dcpu_if.dc_wr),
    .dc_size_o        (dcpu_if.dc_size),
    .dc_addr_o        (dcpu_if.dc_addr),
    .dc_wdata_o       (dcpu_if.dc_wdata),
    .dc_wstrb_o       (dcpu_if.dc_wstrb),
    .dc_rvalid_i      (dcpu_if.dc_rvalid),
    .dc_err_i         (dcpu_if.dc_err),
    .dc_rdata_i       (dcpu_if.dc_rdata),
    .rdata_buf_o      (dc_rdata_buf_r),
    .rdata_buf_valid_o(dc_rdata_buf_valid_r),
    .err_buf_o        (dc_err_buf_r)
  );

  cc_wb_unit wb (
    .clk_i            (clk_i),
    .rst_i            (rst_i),
    .global_stall_i   (global_stall_s),
    .irq_pending_i    (irq_pending_s),
    .is_csr_i         (wb_is_csr_s),
    .valid_i          (mem_wb_valid_r),
    .instr_i          (mem_wb_instr_r),
    .pc_i             (mem_wb_pc_r),
    .regWr_i          (mem_wb_regWr_r),
    .resultSrc_i      (mem_wb_resultSrc_r),
    .trap_illegal_i   (mem_wb_trap_illegal_r),
    .trap_icfault_i   (mem_wb_trap_icfault_r),
    .trap_dcfault_i   (mem_wb_trap_dcfault_r),
    .trap_misaligned_i(mem_wb_trap_misaligned_r),
    .aluRes_i         (mem_wb_aluRes_r),
    .memData_i        (mem_wb_memData_r),
    .csr_rdata_i      (mem_wb_csr_rdata_r),
    .result_o         (wb_result_s),
    .regWr_o          (wb_regWr_final_s),
    .csr_we_o         (csr_we_s),
    .instret_o        (instret_s),
    .commit_o         (wb_commit_s),
    .exc_o            (wb_exc_s),
    .exc_cause_o      (wb_exc_cause_s),
    .exc_tval_o       (wb_exc_tval_s),
    .irq_take_o       (wb_irq_take_s),
    .trap_taken_o     (wb_trap_taken_s),
    .mret_o           (wb_mret_s)
  );

  cc_hazard_unit hazard (
    .ibuf_valid_i            (ibuf_valid_r),
    .ic_rvalid_i             (icpu_if.ic_rvalid),
    .ic_err_i                (icpu_if.ic_err),
    .if_id_valid_i           (if_id_valid_r),
    .if_id_instr_i           (if_id_instr_r),
    .id_ex_valid_i           (id_ex_valid_r),
    .id_ex_instr_i           (id_ex_instr_r),
    .id_ex_dMemRd_i          (id_ex_dMemRd_r),
    .id_ex_regA_i            (id_ex_regA_r),
    .id_ex_regB_i            (id_ex_regB_r),
    .ex_take_i               (ex_take_s),
    .ex_misal_pc_i           (ex_misal_pc_s),
    .ex_mem_valid_i          (ex_mem_valid_r),
    .ex_mem_instr_i          (ex_mem_instr_r),
    .ex_mem_pc_i             (ex_mem_pc_r),
    .ex_mem_regWr_i          (ex_mem_regWr_r),
    .ex_mem_dMemRd_i         (ex_mem_dMemRd_r),
    .ex_mem_trap_misaligned_i(ex_mem_trap_misaligned_r),
    .ex_mem_resultSrc_i      (ex_mem_resultSrc_r),
    .ex_mem_aluRes_i         (ex_mem_aluRes_r),
    .ex_mem_csr_rdata_i      (ex_mem_csr_rdata_r),
    .dc_rvalid_i             (dcpu_if.dc_rvalid),
    .dc_err_i                (dcpu_if.dc_err),
    .dc_rdata_buf_valid_i    (dc_rdata_buf_valid_r),
    .dc_err_buf_i            (dc_err_buf_r),
    .mem_wb_valid_i          (mem_wb_valid_r),
    .mem_wb_instr_i          (mem_wb_instr_r),
    .mem_wb_regWr_i          (mem_wb_regWr_r),
    .wb_result_i             (wb_result_s),
    .wb_trap_taken_i         (wb_trap_taken_s),
    .wb_mret_i               (wb_mret_s),
    .dcache_stall_o          (dcache_stall_s),
    .global_stall_o          (global_stall_s),
    .data_stall_o            (data_stall_s),
    .branch_taken_o          (ex_branch_taken_s),
    .flush_front_o           (flush_s),
    .flush_back_o            (flush_back_s),
    .wb_is_csr_o             (wb_is_csr_s),
    .fwd_srcA_o              (fwd_srcA_s),
    .fwd_srcB_o              (fwd_srcB_s)
  );

  cc_trap_csr #(.HART_ID(HART_ID), .MTVEC_RST(64'h0000_0000_0000_7F00))
  trap_csr (
    .clk_i        (clk_i),
    .rst_i        (rst_i),
    .irq_m_ext_i  (irq_ext_i[7]),
    .irq_m_soft_i (irq_m_soft_i),
    .irq_m_timer_i(irq_m_timer_i),
    .rd_instr_i   (id_ex_instr_r),
    .rd_data_o    (ex_csr_rdata_s),
    .rd_illegal_o (ex_sys_illegal_s),
    .wr_en_i      (csr_we_s),
    .wr_instr_i   (mem_wb_instr_r),
    .wr_data_i    (mem_wb_csr_wdata_r),
    .exc_i        (wb_exc_s),
    .exc_cause_i  (wb_exc_cause_s),
    .exc_tval_i   (wb_exc_tval_s),
    .irq_take_i   (wb_irq_take_s),
    .trap_pc_i    (mem_wb_pc_r),
    .mret_i       (wb_mret_s),
    .instret_i    (instret_s),
    .irq_pending_o(irq_pending_s),
    /* verilator lint_off PINCONNECTEMPTY */ // WFI runs as a NOP here
    .wfi_wake_o   (),
    /* verilator lint_on PINCONNECTEMPTY */
    .trap_vec_o   (trap_vec_s),
    .mepc_o       (mepc_s)
  );

  // Register file: WBR=1 so the k=3 RAW (WB writes same cycle ID reads) is
  // resolved combinatorially without a pipeline stall.
  as_regfile #(.WBR(1)) regfile (
    .clk_i     (clk_i),
    .rst_i     (rst_i),
    .we_i      (wb_regWr_final_s),
    .raddr01_i (if_id_instr_r[19:15]),
    .raddr02_i (if_id_instr_r[24:20]),
    .waddr01_i (mem_wb_instr_r[11:7]),
    .wdata01_i (wb_result_s),
    .rdata01_o (rf_rdata1_s),
    .rdata02_o (rf_rdata2_s)
  );

  // ── Scan chain ─────────────────────────────────────────────────────────────
  assign clk_mux_s   = sc01_shift_i ? tck_i : gated_clk_s;
  // CLOCK GATE: scan-test infrastructure — clk_i gated by capture enable (Guideline 8 exception).
  assign gated_clk_s = clk_i && dr_cap_i;

  scan_cell sc01 (clk_mux_s, rst_i, sc01_shift_i, 1'b0, sc01_tdi_i, and_in01_s, sc01_01_s);
  scan_cell sc02 (clk_mux_s, rst_i, sc01_shift_i, 1'b0, sc01_01_s, and_in02_s, sc01_02_s);
  assign and_out_s = and_in01_s & and_in02_s;
  scan_cell sc03 (.tck_i(clk_mux_s), .trst_i(rst_i), .scan_shift_i(sc01_shift_i),
                  .data_i(and_out_s), .ser_i(sc01_02_s), .data_o(), .ser_o(sc01_03_s));
  scan_cell sc04 (.tck_i(clk_mux_s), .trst_i(rst_i), .scan_shift_i(sc01_shift_i),
                  .data_i(1'b0), .ser_i(sc01_03_s), .data_o(), .ser_o(sc01_tdo_o));

endmodule : cc_cpupipefwd
