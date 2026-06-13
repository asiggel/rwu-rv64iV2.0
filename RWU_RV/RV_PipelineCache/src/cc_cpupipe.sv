// cc_cpupipe.sv  –  RV_PipelineCache, Step 1: stall-only pipeline
//
// 5-stage in-order pipeline (IF / ID / EX / MEM / WB).
// Hazard strategy: stall-only, no forwarding.
//   RAW:     detected in ID vs EX/MEM/WB; freeze IF+ID, bubble into EX.
//   Control: branch/jump resolved in EX; flush IF+ID (2-cycle penalty).
//   Cache:   ICache/DCache miss: global pipeline freeze.
// Interface: identical to as_cpux (icpu_if / dcpu_if).
// CSR/IRQ:   committed at WB stage.
`timescale 1ns/1ps

import as_pack::*;

module cc_cpupipe (
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
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [irq_total_num_ext_c-1:0] irq_ext_i
    /* verilator lint_on UNUSEDSIGNAL */
);

  localparam int XLEN = reg_width;

  // ─── 1. typedefs / localparams ────────────────────────────────────────────
  // (none beyond package)

  // ─── 2. ALL signal declarations ───────────────────────────────────────────

  // ── Stall / flush ──────────────────────────────────────────────────────────
  logic icache_stall_s;   // IC has no instruction ready
  logic dcache_stall_s;   // DC load is waiting for rvalid
  logic global_stall_s;   // = icache_stall | dcache_stall  – freezes all stages
  logic data_stall_s;     // RAW hazard: freezes IF+ID, bubbles ID/EX
  logic flush_s;          // branch taken (EX) or trap/mret (WB)

  // ── PC / Fetch ─────────────────────────────────────────────────────────────
  logic [iaddr_width-1:0] PC_r;           // next address to fetch
  logic [iaddr_width-1:0] fetch_pc_r;    // PC sent with the outstanding ic_req
  logic                   fetch_in_flight_r; // ic_req sent, waiting for ic_rvalid
  logic                   discard_ic_r;  // flush happened while fetch in-flight
  logic                   start_fetch_s;

  // ── Instruction buffer ─────────────────────────────────────────────────────
  // Captures ic_rvalid response when pipeline stall prevents IF/ID from advancing.
  logic [31:0]            ibuf_instr_r;
  logic [63:0]            ibuf_pc_r;
  logic                   ibuf_valid_r;
  logic                   if_id_advance_s;

  // ── IF/ID pipeline register ────────────────────────────────────────────────
  logic [instr_width-1:0] if_id_instr_r;
  logic [iaddr_width-1:0] if_id_pc_r;
  logic                   if_id_valid_r;

  // ── ID stage ───────────────────────────────────────────────────────────────
  logic                   id_regWr_s;
  logic                   id_dMemRd_s;
  logic                   id_dMemWr_s;
  logic                   id_aluSrcB_s;
  mux_a_t                 id_aluSrcA_s;
  result_src_t            id_resultSrc_s;
  imm_src_t               id_immSrc_s;
  alu_op_t                id_aluOp_s;
  br_op_t                 id_brOp_s;
  logic                   id_jump_s;
  logic                   id_trap_illegal_s;
  logic [reg_width-1:0]   id_regA_s;
  logic [reg_width-1:0]   id_regB_s;
  logic [reg_width-1:0]   id_immExt_s;

  // ── ID/EX pipeline register ────────────────────────────────────────────────
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
  logic [reg_width-1:0]   id_ex_regA_r;
  logic [reg_width-1:0]   id_ex_regB_r;
  logic [reg_width-1:0]   id_ex_immExt_r;

  // ── EX stage ───────────────────────────────────────────────────────────────
  logic [reg_width-1:0]   ex_srcA_s;
  logic [reg_width-1:0]   ex_srcB_s;
  logic [reg_width-1:0]   ex_aluRes_s;
  logic                   ex_take_s;
  logic [iaddr_width-1:0] ex_PCorRS1_s;
  logic [iaddr_width-1:0] ex_PCbr_s;
  logic [reg_width-1:0]   ex_csr_rdata_s;  // CSR read value → rd
  logic [reg_width-1:0]   ex_csr_wdata_s;  // value written to CSR (rs1 or uimm)
  logic [63:0]            ex_dc_wdata_s;
  logic [7:0]             ex_dc_wstrb_s;
  logic                   ex_branch_taken_s;

  // ── EX/MEM pipeline register ───────────────────────────────────────────────
  logic [instr_width-1:0] ex_mem_instr_r;
  logic [iaddr_width-1:0] ex_mem_pc_r;
  logic                   ex_mem_valid_r;
  logic                   ex_mem_regWr_r;
  logic                   ex_mem_dMemRd_r;
  logic                   ex_mem_dMemWr_r;
  result_src_t            ex_mem_resultSrc_r;
  logic                   ex_mem_trap_illegal_r;
  logic [reg_width-1:0]   ex_mem_aluRes_r;
  logic [reg_width-1:0]   ex_mem_csr_rdata_r;
  logic [reg_width-1:0]   ex_mem_csr_wdata_r;
  logic [63:0]            ex_mem_dc_wdata_r;
  logic [7:0]             ex_mem_dc_wstrb_r;

  // ── MEM stage ──────────────────────────────────────────────────────────────
  logic                   dc_req_sent_r;     // DCache request pulse already sent
  logic [reg_width-1:0]   dc_rdata_buf_r;   // dc_rdata latch when icache stalls same cycle
  logic                   dc_rdata_buf_valid_r;

  // ── MEM/WB pipeline register ───────────────────────────────────────────────
  logic [instr_width-1:0] mem_wb_instr_r;
  logic [iaddr_width-1:0] mem_wb_pc_r;
  logic                   mem_wb_valid_r;
  logic                   mem_wb_regWr_r;
  result_src_t            mem_wb_resultSrc_r;
  logic                   mem_wb_trap_illegal_r;
  logic [reg_width-1:0]   mem_wb_aluRes_r;
  logic [reg_width-1:0]   mem_wb_memData_r;
  logic [reg_width-1:0]   mem_wb_csr_rdata_r;
  logic [reg_width-1:0]   mem_wb_csr_wdata_r;

  // ── WB stage ───────────────────────────────────────────────────────────────
  logic [reg_width-1:0]   wb_result_s;
  logic                   wb_regWr_final_s;
  logic                   wb_commit_s;
  logic                   wb_committed_r;  // one-shot guard: WB commits exactly once per instruction
  logic                   wb_trap_taken_s;
  logic                   wb_mret_s;
  logic                   wb_is_mret_s;
  logic                   wb_trap_illegal_s;
  logic                   wb_trap_misaligned_s;
  logic                   wb_irq_pending_s;

  // ── Register file ──────────────────────────────────────────────────────────
  logic [reg_width-1:0] rf_rdata1_s, rf_rdata2_s;

  // ── CSR registers ──────────────────────────────────────────────────────────
  logic [63:0] csr_mepc_r, csr_mcause_r, csr_mtvec_r;
  logic [63:0] csr_mstatus_r, csr_mie_r, csr_mip_r;
  logic        csr_mstatus_mie, csr_mstatus_mpie;

  // ── IRQ ────────────────────────────────────────────────────────────────────
  logic        irq_sync_r;

  // ── Hazard helpers ─────────────────────────────────────────────────────────
  logic [4:0]  id_rs1_s, id_rs2_s;
  logic [4:0]  ex_rd_s, mem_rd_s, wb_rd_s;
  logic        id_is_csr_s, ex_is_csr_s, mem_is_csr_s, wb_is_csr_s;

  // ── Scan chain ─────────────────────────────────────────────────────────────
  logic and_in01_s, sc01_01_s, sc01_02_s, sc01_03_s;
  logic and_in02_s, and_out_s;
  logic gated_clk_s, clk_mux_s;

  // ─── 3. assign statements ─────────────────────────────────────────────────

  assign icpu_if.ic_flush = 1'b0;
  assign dcpu_if.dc_flush = 1'b0;

  // ── Stall / flush ──────────────────────────────────────────────────────────
  assign global_stall_s = icache_stall_s | dcache_stall_s;

  // ICache stall: no instruction available (not in buffer, not arriving now)
  assign icache_stall_s = !ibuf_valid_r && !icpu_if.ic_rvalid;

  // DCache stall: load waiting – cleared when dc_rvalid fires OR data already buffered
  assign dcache_stall_s = ex_mem_valid_r && ex_mem_dMemRd_r
                          && !dcpu_if.dc_rvalid && !dc_rdata_buf_valid_r;

  // Fetch: send ic_req when
  //  (a) nothing in flight AND buffer empty: fresh start (after reset / stall recovery)
  //  (b) ic_rvalid arriving AND pipeline can accept: overlap next req with current response
  assign start_fetch_s =
    (!fetch_in_flight_r && !ibuf_valid_r && !flush_s && !rst_i)
    ||
    (icpu_if.ic_rvalid && !discard_ic_r && !ibuf_valid_r &&
     !data_stall_s && !dcache_stall_s && !flush_s && !rst_i);

  assign icpu_if.ic_req  = start_fetch_s;
  assign icpu_if.ic_addr = PC_r;

  // IF/ID advances when an instruction is available AND no stall prevents it
  assign if_id_advance_s = (ibuf_valid_r || (icpu_if.ic_rvalid && !discard_ic_r))
                           && !data_stall_s && !dcache_stall_s;

  // Branch/jump taken: resolved in EX stage
  assign ex_branch_taken_s = id_ex_valid_r && ex_take_s && !global_stall_s;

  // Flush: branch/jump in EX, or trap/mret committing in WB
  assign flush_s = ex_branch_taken_s | wb_trap_taken_s | wb_mret_s;

  // ── RAW hazard detection ───────────────────────────────────────────────────
  assign id_rs1_s = if_id_instr_r[19:15];
  assign id_rs2_s = if_id_instr_r[24:20];
  assign ex_rd_s  = id_ex_instr_r[11:7];
  assign mem_rd_s = ex_mem_instr_r[11:7];
  assign wb_rd_s  = mem_wb_instr_r[11:7];

  // CSR hazard: conservative stall — hold any CSR instr in ID until the
  // pipeline is clear of all earlier CSR instrs (CSR writes commit at WB;
  // no forwarding path exists from WB back to EX for CSR values).
  assign id_is_csr_s  = if_id_valid_r  && (if_id_instr_r[6:0] == 7'b1110011) && (if_id_instr_r[14:12] != 3'b000);
  assign ex_is_csr_s  = id_ex_valid_r  && (id_ex_instr_r[6:0] == 7'b1110011) && (id_ex_instr_r[14:12] != 3'b000);
  assign mem_is_csr_s = ex_mem_valid_r && (ex_mem_instr_r[6:0] == 7'b1110011) && (ex_mem_instr_r[14:12] != 3'b000);
  assign wb_is_csr_s  = mem_wb_valid_r && (mem_wb_instr_r[6:0] == 7'b1110011) && (mem_wb_instr_r[14:12] != 3'b000);

  always_comb begin
    data_stall_s = 1'b0;
    if (if_id_valid_r) begin
      if ((id_ex_regWr_r  && ex_rd_s  != 5'b0 &&
           (ex_rd_s  == id_rs1_s || ex_rd_s  == id_rs2_s)) ||
          (ex_mem_regWr_r && mem_rd_s != 5'b0 &&
           (mem_rd_s == id_rs1_s || mem_rd_s == id_rs2_s)) ||
          (mem_wb_regWr_r && wb_rd_s  != 5'b0 &&
           (wb_rd_s  == id_rs1_s || wb_rd_s  == id_rs2_s)))
        data_stall_s = 1'b1;
      if (id_is_csr_s && (ex_is_csr_s || mem_is_csr_s || wb_is_csr_s))
        data_stall_s = 1'b1;
    end
  end

  // ── DCache interface ───────────────────────────────────────────────────────
  assign dcpu_if.dc_addr  = ex_mem_aluRes_r;
  assign dcpu_if.dc_wr    = ex_mem_dMemWr_r;
  assign dcpu_if.dc_size  = ex_mem_instr_r[14:12];
  assign dcpu_if.dc_wdata = ex_mem_dc_wdata_r;
  assign dcpu_if.dc_wstrb = ex_mem_dc_wstrb_r;

  // dc_req: 1-cycle pulse per MEM instruction (load or store)
  assign dcpu_if.dc_req = ex_mem_valid_r &&
                          (ex_mem_dMemRd_r || ex_mem_dMemWr_r) &&
                          !dc_req_sent_r;

  // ── ID: immediate extension (from IF/ID register) ─────────────────────────
  always_comb
    case (id_immSrc_s)
      IMM_I   : id_immExt_s = {{(XLEN-12){if_id_instr_r[31]}},
                               if_id_instr_r[31:20]};
      IMM_S   : id_immExt_s = {{(XLEN-12){if_id_instr_r[31]}},
                               if_id_instr_r[31:25], if_id_instr_r[11:7]};
      IMM_B   : id_immExt_s = {{(XLEN-12){if_id_instr_r[31]}},
                               if_id_instr_r[7], if_id_instr_r[30:25],
                               if_id_instr_r[11:8], 1'b0};
      IMM_J   : id_immExt_s = {{(XLEN-20){if_id_instr_r[31]}},
                               if_id_instr_r[19:12], if_id_instr_r[20],
                               if_id_instr_r[30:21], 1'b0};
      IMM_U   : id_immExt_s = {{(XLEN-32){if_id_instr_r[31]}},
                               if_id_instr_r[31:12], 12'b0};
      default : id_immExt_s = {XLEN{1'b0}};
    endcase

  assign id_regA_s = rf_rdata1_s;
  assign id_regB_s = rf_rdata2_s;

  // ── EX: source muxes ───────────────────────────────────────────────────────
  always_comb
    case (id_ex_aluSrcA_r)
      SRC_REGA : ex_srcA_s = id_ex_regA_r;
      SRC_PC   : ex_srcA_s = id_ex_pc_r;
      SRC_ZERO : ex_srcA_s = {XLEN{1'b0}};
      default  : ex_srcA_s = id_ex_regA_r;
    endcase

  assign ex_srcB_s    = id_ex_aluSrcB_r ? id_ex_immExt_r : id_ex_regB_r;
  assign ex_PCorRS1_s = id_ex_jump_r    ? id_ex_regA_r   : id_ex_pc_r;
  assign ex_PCbr_s    = ex_PCorRS1_s + id_ex_immExt_r;

  // ── EX: CSR read value (goes to rd via result mux) ────────────────────────
  always_comb begin
    ex_csr_rdata_s = 64'h0;
    if ((id_ex_instr_r[6:0] == 7'b1110011) && (id_ex_instr_r[14:12] != 3'b000))
      case (id_ex_instr_r[31:20])
        12'h300: ex_csr_rdata_s = csr_mstatus_r;
        12'h304: ex_csr_rdata_s = csr_mie_r;
        12'h305: ex_csr_rdata_s = csr_mtvec_r;
        12'h341: ex_csr_rdata_s = csr_mepc_r;
        12'h342: ex_csr_rdata_s = csr_mcause_r;
        12'h344: ex_csr_rdata_s = csr_mip_r;
        default: ex_csr_rdata_s = 64'h0;
      endcase
  end

  // ── EX: CSR write value (written to CSR register at WB) ───────────────────
  always_comb begin
    // func3[2]=1 means immediate (CSRRWI/CSRRSI/CSRRCI), else rs1
    if (id_ex_instr_r[14])
      ex_csr_wdata_s = {{(XLEN-5){1'b0}}, id_ex_instr_r[19:15]};
    else
      ex_csr_wdata_s = id_ex_regA_r;
  end

  // ── EX: store byte-enable / data ──────────────────────────────────────────
  always_comb begin
    ex_dc_wdata_s = id_ex_regB_r;
    ex_dc_wstrb_s = 8'hFF;
    if (id_ex_dMemWr_r)
      case (id_ex_instr_r[14:12])
        3'b000: begin
          ex_dc_wdata_s = {8{id_ex_regB_r[7:0]}};
          ex_dc_wstrb_s = 8'h01 << ex_aluRes_s[2:0];
        end
        3'b001: begin
          ex_dc_wdata_s = {4{id_ex_regB_r[15:0]}};
          ex_dc_wstrb_s = 8'h03 << {ex_aluRes_s[2:1], 1'b0};
        end
        3'b010: begin
          ex_dc_wdata_s = {2{id_ex_regB_r[31:0]}};
          ex_dc_wstrb_s = 8'h0F << {ex_aluRes_s[2], 2'b0};
        end
        default:;
      endcase
  end

  // ── WB: outputs ───────────────────────────────────────────────────────────
  assign ir_o = mem_wb_instr_r;

  assign wb_is_mret_s = (mem_wb_instr_r[6:0]  == 7'b1110011) &&
                        (mem_wb_instr_r[14:12] == 3'b000)     &&
                        (mem_wb_instr_r[31:20] == 12'h302);

  // wb_committed_r guards against repeated commits when WB is frozen by global_stall.
  // Without this, jal/jalr rd writes are suppressed whenever ICache stalls in WB.
  assign wb_commit_s  = mem_wb_valid_r && !wb_committed_r;
  assign csr_mstatus_mie  = csr_mstatus_r[3];
  assign csr_mstatus_mpie = csr_mstatus_r[7];
  assign wb_irq_pending_s = csr_mip_r[11] && csr_mie_r[11] && csr_mstatus_mie;
  assign wb_trap_illegal_s = mem_wb_trap_illegal_r;

  always_comb begin
    wb_trap_misaligned_s = 1'b0;
    if (mem_wb_instr_r[6:0] == 7'b0000011 || mem_wb_instr_r[6:0] == 7'b0100011)
      case (mem_wb_instr_r[14:12])
        3'b001, 3'b101: wb_trap_misaligned_s = mem_wb_aluRes_r[0];
        3'b010:         wb_trap_misaligned_s = (mem_wb_aluRes_r[1:0] != 2'b00);
        3'b011:         wb_trap_misaligned_s = (mem_wb_aluRes_r[2:0] != 3'b000);
        default:;
      endcase
  end

  assign wb_trap_taken_s = wb_commit_s && !wb_is_mret_s &&
                           (wb_trap_illegal_s || wb_trap_misaligned_s || wb_irq_pending_s);
  assign wb_mret_s       = wb_commit_s && wb_is_mret_s;

  // ── WB: result mux ────────────────────────────────────────────────────────
  always_comb
    case (mem_wb_resultSrc_r)
      RES_ALU : wb_result_s = mem_wb_aluRes_r;
      RES_MEM : wb_result_s = mem_wb_memData_r;
      RES_PC4 : wb_result_s = mem_wb_pc_r + 64'd4;   // JAL/JALR return address
      RES_CSR : wb_result_s = mem_wb_csr_rdata_r;
      default : wb_result_s = {XLEN{1'b0}};
    endcase

  assign wb_regWr_final_s = mem_wb_regWr_r && wb_commit_s && !wb_trap_taken_s;

  // ─── 4. always_comb (all in assign/always_comb above) ─────────────────────

  // ─── 5. always_ff blocks ──────────────────────────────────────────────────

  // ── PC register ───────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      PC_r <= 64'h0;
    else begin
      if      (wb_trap_taken_s)        PC_r <= {csr_mtvec_r[63:2], 2'b00};
      else if (wb_mret_s)              PC_r <= csr_mepc_r;
      else if (ex_branch_taken_s)      PC_r <= ex_PCbr_s;
      else if (start_fetch_s)          PC_r <= PC_r + 64'd4;
    end
  end

  // ── PC latched at ic_req (= fetch_pc_r) ───────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)              fetch_pc_r <= 64'h0;
    else if (start_fetch_s) fetch_pc_r <= PC_r;
  end

  // ── Fetch in-flight ────────────────────────────────────────────────────────
  // start_fetch has priority: a new request is in flight from this cycle.
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      fetch_in_flight_r <= 1'b0;
    else begin
      if      (flush_s)          fetch_in_flight_r <= 1'b0;
      else if (start_fetch_s)    fetch_in_flight_r <= 1'b1;
      else if (icpu_if.ic_rvalid) fetch_in_flight_r <= 1'b0;
    end
  end

  // ── Discard flag: flush while fetch in-flight ──────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      discard_ic_r <= 1'b0;
    else begin
      if      (flush_s && fetch_in_flight_r && !icpu_if.ic_rvalid) discard_ic_r <= 1'b1;
      else if (icpu_if.ic_rvalid && discard_ic_r)       discard_ic_r <= 1'b0;
    end
  end

  // ── Instruction buffer ─────────────────────────────────────────────────────
  // Stores IC response only when the pipeline cannot yet accept it (stall).
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      ibuf_valid_r <= 1'b0;
      ibuf_instr_r <= 32'h00000013;
      ibuf_pc_r    <= 64'h0;
    end else begin
      if (flush_s) begin
        ibuf_valid_r <= 1'b0;
      end else if (icpu_if.ic_rvalid && !discard_ic_r &&
                   (data_stall_s || dcache_stall_s)) begin
        // Response arrived but pipeline is stalled – buffer it
        ibuf_instr_r <= icpu_if.ic_rdata;
        ibuf_pc_r    <= fetch_pc_r;
        ibuf_valid_r <= 1'b1;
      end else if (ibuf_valid_r && if_id_advance_s) begin
        ibuf_valid_r <= 1'b0;  // consumed by IF/ID
      end
    end
  end

  // ── IF/ID pipeline register ────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      if_id_instr_r <= 32'h00000013;
      if_id_pc_r    <= 64'h0;
      if_id_valid_r <= 1'b0;
    end else begin
      if (flush_s) begin
        if_id_instr_r <= 32'h00000013;
        if_id_valid_r <= 1'b0;
      end else if (if_id_advance_s) begin
        if_id_valid_r <= 1'b1;
        if (ibuf_valid_r) begin
          if_id_instr_r <= ibuf_instr_r;  // from buffer (after stall recovery)
          if_id_pc_r    <= ibuf_pc_r;
        end else begin
          if_id_instr_r <= icpu_if.ic_rdata;  // bypass: direct from ICache
          if_id_pc_r    <= fetch_pc_r;
        end
      end
      // else: hold (global stall or data stall with no new instruction)
    end
  end

  // ── ID/EX pipeline register ────────────────────────────────────────────────
  localparam logic [instr_width-1:0] NOP_INSTR = 32'h00000013;

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      id_ex_valid_r        <= 1'b0;
      id_ex_instr_r        <= NOP_INSTR;
      id_ex_pc_r           <= 64'h0;
      id_ex_regWr_r        <= 1'b0;
      id_ex_dMemRd_r       <= 1'b0;
      id_ex_dMemWr_r       <= 1'b0;
      id_ex_aluSrcB_r      <= 1'b0;
      id_ex_aluSrcA_r      <= SRC_REGA;
      id_ex_resultSrc_r    <= RES_ALU;
      id_ex_aluOp_r        <= ALU_ADD;
      id_ex_brOp_r         <= BR_NONE;
      id_ex_jump_r         <= 1'b0;
      id_ex_trap_illegal_r <= 1'b0;
      id_ex_regA_r         <= {XLEN{1'b0}};
      id_ex_regB_r         <= {XLEN{1'b0}};
      id_ex_immExt_r       <= {XLEN{1'b0}};
    end else if (!global_stall_s) begin
      if (flush_s || data_stall_s) begin
        id_ex_valid_r        <= 1'b0;
        id_ex_instr_r        <= NOP_INSTR;
        id_ex_regWr_r        <= 1'b0;
        id_ex_dMemRd_r       <= 1'b0;
        id_ex_dMemWr_r       <= 1'b0;
        id_ex_aluSrcB_r      <= 1'b0;
        id_ex_aluSrcA_r      <= SRC_REGA;
        id_ex_resultSrc_r    <= RES_ALU;
        id_ex_aluOp_r        <= ALU_ADD;
        id_ex_brOp_r         <= BR_NONE;
        id_ex_jump_r         <= 1'b0;
        id_ex_trap_illegal_r <= 1'b0;
        id_ex_regA_r         <= {XLEN{1'b0}};
        id_ex_regB_r         <= {XLEN{1'b0}};
        id_ex_immExt_r       <= {XLEN{1'b0}};
      end else begin
        id_ex_valid_r        <= if_id_valid_r;
        id_ex_instr_r        <= if_id_instr_r;
        id_ex_pc_r           <= if_id_pc_r;
        id_ex_regWr_r        <= id_regWr_s  & if_id_valid_r;
        id_ex_dMemRd_r       <= id_dMemRd_s & if_id_valid_r;
        id_ex_dMemWr_r       <= id_dMemWr_s & if_id_valid_r;
        id_ex_aluSrcB_r      <= id_aluSrcB_s;
        id_ex_aluSrcA_r      <= id_aluSrcA_s;
        id_ex_resultSrc_r    <= id_resultSrc_s;
        id_ex_aluOp_r        <= id_aluOp_s;
        id_ex_brOp_r         <= id_brOp_s;
        id_ex_jump_r         <= id_jump_s;
        id_ex_trap_illegal_r <= id_trap_illegal_s & if_id_valid_r;
        id_ex_regA_r         <= id_regA_s;
        id_ex_regB_r         <= id_regB_s;
        id_ex_immExt_r       <= id_immExt_s;
      end
    end
  end

  // ── EX/MEM pipeline register ───────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      ex_mem_valid_r        <= 1'b0;
      ex_mem_instr_r        <= NOP_INSTR;
      ex_mem_pc_r           <= 64'h0;
      ex_mem_regWr_r        <= 1'b0;
      ex_mem_dMemRd_r       <= 1'b0;
      ex_mem_dMemWr_r       <= 1'b0;
      ex_mem_resultSrc_r    <= RES_ALU;
      ex_mem_trap_illegal_r <= 1'b0;
      ex_mem_aluRes_r       <= {XLEN{1'b0}};
      ex_mem_csr_rdata_r    <= 64'h0;
      ex_mem_csr_wdata_r    <= 64'h0;
      ex_mem_dc_wdata_r     <= 64'h0;
      ex_mem_dc_wstrb_r     <= 8'h0;
    end else if (!global_stall_s) begin
      if (wb_trap_taken_s || wb_mret_s) begin
        // WB-stage event: instructions in EX are speculative and must be killed.
        // ex_branch_taken_s is NOT included: the branch/JAL in EX is the cause of
        // the flush and must advance through MEM→WB to commit its rd write (e.g.
        // jal x30 writes the return address; killing it here loses that value).
        ex_mem_valid_r        <= 1'b0;
        ex_mem_regWr_r        <= 1'b0;
        ex_mem_dMemRd_r       <= 1'b0;
        ex_mem_dMemWr_r       <= 1'b0;
        ex_mem_trap_illegal_r <= 1'b0;
      end else begin
        ex_mem_valid_r        <= id_ex_valid_r;
        ex_mem_instr_r        <= id_ex_instr_r;
        ex_mem_pc_r           <= id_ex_pc_r;
        ex_mem_regWr_r        <= id_ex_regWr_r;
        ex_mem_dMemRd_r       <= id_ex_dMemRd_r;
        ex_mem_dMemWr_r       <= id_ex_dMemWr_r;
        ex_mem_resultSrc_r    <= id_ex_resultSrc_r;
        ex_mem_trap_illegal_r <= id_ex_trap_illegal_r;
        ex_mem_aluRes_r       <= ex_aluRes_s;
        ex_mem_csr_rdata_r    <= ex_csr_rdata_s;
        ex_mem_csr_wdata_r    <= ex_csr_wdata_s;
        ex_mem_dc_wdata_r     <= ex_dc_wdata_s;
        ex_mem_dc_wstrb_r     <= ex_dc_wstrb_s;
      end
    end
  end

  // ── DCache request one-shot ────────────────────────────────────────────────
  // Ensure dc_req is a 1-cycle pulse even when the pipeline stalls.
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      dc_req_sent_r <= 1'b0;
    else begin
      if (!global_stall_s)
        dc_req_sent_r <= 1'b0;   // instruction leaves MEM next cycle; reset for next
      else if (dcpu_if.dc_req)
        dc_req_sent_r <= 1'b1;
    end
  end

  // ── DCache read-data buffer ────────────────────────────────────────────────
  // If dc_rvalid fires while icache_stall prevents MEM/WB advancement, latch
  // the data so it is not lost when dc_rvalid de-asserts next cycle.
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      dc_rdata_buf_valid_r <= 1'b0;
      dc_rdata_buf_r       <= {XLEN{1'b0}};
    end else begin
      if (!global_stall_s) begin
        dc_rdata_buf_valid_r <= 1'b0;  // instruction advancing; consumed
      end else if (dcpu_if.dc_rvalid && ex_mem_valid_r && ex_mem_dMemRd_r
                   && !dc_rdata_buf_valid_r) begin
        dc_rdata_buf_r       <= dcpu_if.dc_rdata;
        dc_rdata_buf_valid_r <= 1'b1;
      end
    end
  end

  // ── MEM/WB pipeline register ───────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      mem_wb_valid_r        <= 1'b0;
      mem_wb_instr_r        <= NOP_INSTR;
      mem_wb_pc_r           <= 64'h0;
      mem_wb_regWr_r        <= 1'b0;
      mem_wb_resultSrc_r    <= RES_ALU;
      mem_wb_trap_illegal_r <= 1'b0;
      mem_wb_aluRes_r       <= {XLEN{1'b0}};
      mem_wb_memData_r      <= {XLEN{1'b0}};
      mem_wb_csr_rdata_r    <= 64'h0;
      mem_wb_csr_wdata_r    <= 64'h0;
    end else if (!global_stall_s) begin
      mem_wb_valid_r        <= ex_mem_valid_r;
      mem_wb_instr_r        <= ex_mem_instr_r;
      mem_wb_pc_r           <= ex_mem_pc_r;
      mem_wb_regWr_r        <= ex_mem_regWr_r;
      mem_wb_resultSrc_r    <= ex_mem_resultSrc_r;
      mem_wb_trap_illegal_r <= ex_mem_trap_illegal_r;
      mem_wb_aluRes_r       <= ex_mem_aluRes_r;
      mem_wb_memData_r      <= dc_rdata_buf_valid_r ? dc_rdata_buf_r : dcpu_if.dc_rdata;
      mem_wb_csr_rdata_r    <= ex_mem_csr_rdata_r;
      mem_wb_csr_wdata_r    <= ex_mem_csr_wdata_r;
    end
  end

  // ── WB one-shot commit guard ───────────────────────────────────────────────
  // When global_stall freezes the pipeline, WB must still commit exactly once.
  // Reset whenever !global_stall (instruction leaves WB); set after first commit.
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      wb_committed_r <= 1'b0;
    else if (!global_stall_s)
      wb_committed_r <= 1'b0;
    else if (wb_commit_s)
      wb_committed_r <= 1'b1;
  end

  // ── IRQ synchroniser (1 FF) ────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) irq_sync_r <= 1'b0;
    else       irq_sync_r <= irq_ext_i[7];
  end

  // ── CSR: MIP ──────────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) csr_mip_r <= 64'h0;
    else       csr_mip_r[11] <= irq_sync_r;
  end

  // ── CSR: MIE ──────────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      csr_mie_r <= 64'h0000000000000800;
    else if (wb_commit_s && !wb_trap_taken_s &&
             mem_wb_instr_r[6:0] == 7'b1110011 &&
             mem_wb_instr_r[31:20] == 12'h304)
      case (mem_wb_instr_r[14:12])
        3'b001, 3'b101: csr_mie_r <= mem_wb_csr_wdata_r;
        3'b010, 3'b110: csr_mie_r <= csr_mie_r | mem_wb_csr_wdata_r;
        3'b011, 3'b111: csr_mie_r <= csr_mie_r & ~mem_wb_csr_wdata_r;
        default:;
      endcase
  end

  // ── CSR: MSTATUS ──────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      csr_mstatus_r <= 64'h0000000000001808;
    else if (wb_trap_taken_s) begin
      csr_mstatus_r[7] <= csr_mstatus_mie;
      csr_mstatus_r[3] <= 1'b0;
    end else if (wb_mret_s) begin
      csr_mstatus_r[3] <= csr_mstatus_mpie;
      csr_mstatus_r[7] <= 1'b1;
    end else if (wb_commit_s && !wb_trap_taken_s &&
                 mem_wb_instr_r[6:0] == 7'b1110011 &&
                 mem_wb_instr_r[31:20] == 12'h300)
      case (mem_wb_instr_r[14:12])
        3'b001, 3'b101: csr_mstatus_r <= mem_wb_csr_wdata_r;
        3'b010, 3'b110: csr_mstatus_r <= csr_mstatus_r | mem_wb_csr_wdata_r;
        3'b011, 3'b111: csr_mstatus_r <= csr_mstatus_r & ~mem_wb_csr_wdata_r;
        default:;
      endcase
  end

  // ── CSR: MEPC ─────────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      csr_mepc_r <= 64'h0;
    else if (wb_trap_taken_s) begin
      if (wb_trap_illegal_s || wb_trap_misaligned_s)
        csr_mepc_r <= mem_wb_pc_r;
      else  // IRQ
        csr_mepc_r <= mem_wb_pc_r + 64'd4;
    end else if (wb_commit_s && !wb_trap_taken_s &&
                 mem_wb_instr_r[6:0] == 7'b1110011 &&
                 mem_wb_instr_r[31:20] == 12'h341)
      case (mem_wb_instr_r[14:12])
        3'b001, 3'b101: csr_mepc_r <= mem_wb_csr_wdata_r;
        3'b010, 3'b110: csr_mepc_r <= csr_mepc_r | mem_wb_csr_wdata_r;
        3'b011, 3'b111: csr_mepc_r <= csr_mepc_r & ~mem_wb_csr_wdata_r;
        default:;
      endcase
  end

  // ── CSR: MTVEC ────────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      csr_mtvec_r <= 64'h0000000000007F00;
    else if (wb_commit_s && !wb_trap_taken_s &&
             mem_wb_instr_r[6:0] == 7'b1110011 &&
             mem_wb_instr_r[31:20] == 12'h305)
      case (mem_wb_instr_r[14:12])
        3'b001, 3'b101: csr_mtvec_r <= mem_wb_csr_wdata_r;
        3'b010, 3'b110: csr_mtvec_r <= csr_mtvec_r | mem_wb_csr_wdata_r;
        3'b011, 3'b111: csr_mtvec_r <= csr_mtvec_r & ~mem_wb_csr_wdata_r;
        default:;
      endcase
  end

  // ── CSR: MCAUSE ───────────────────────────────────────────────────────────
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      csr_mcause_r <= 64'h0;
    else if (wb_trap_taken_s) begin
      if      (wb_trap_illegal_s)    csr_mcause_r <= 64'd2;
      else if (wb_trap_misaligned_s) begin
        if      (mem_wb_instr_r[6:0] == 7'b0000011) csr_mcause_r <= 64'd4;
        else if (mem_wb_instr_r[6:0] == 7'b0100011) csr_mcause_r <= 64'd6;
        else                                         csr_mcause_r <= 64'd0;
      end else if (wb_irq_pending_s) csr_mcause_r <= {1'b1, 63'd11};
    end
  end

  // ─── 6. Module instantiations ─────────────────────────────────────────────

  // Register file: combinatorial reads (ID stage), clocked write (WB stage)
  as_regfile regfile (
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

  // Instruction decoder (combinatorial, operates on IF/ID instruction)
  as_instr_decode control (
    .instr_opcode_i      (if_id_instr_r[6:0]),
    .instr_func3_i       (if_id_instr_r[14:12]),
    .instr_func7b5_i     (if_id_instr_r[30]),
    .take_i              (1'b0),
    .mux_resultSrc_o     (id_resultSrc_s),
    .en_dMemWr_o         (id_dMemWr_s),
    .en_dMemRd_o         (id_dMemRd_s),
    .mux_aluSrcB_o       (id_aluSrcB_s),
    .mux_aluSrcA_o       (id_aluSrcA_s),
    .en_regWr_o          (id_regWr_s),
    .mux_jump_o          (id_jump_s),
    .sel_immSrc_o        (id_immSrc_s),
    .alu_op_o            (id_aluOp_s),
    .br_op_o             (id_brOp_s),
    .trap_illegal_instr_o(id_trap_illegal_s)
  );

  // ALU (EX stage, combinatorial)
  as_alu alua (
    .data01_i   (ex_srcA_s),
    .data02_i   (ex_srcB_s),
    .alu_op_i   (id_ex_aluOp_r),
    .aluResult_o(ex_aluRes_s)
  );

  // Branch ALU (EX stage, combinatorial)
  as_alu_branch alub (
    .data01_i(ex_srcA_s),
    .data02_i(ex_srcB_s),
    .br_op_i (id_ex_brOp_r),
    .take_o  (ex_take_s)
  );

  // ── Scan chain (identical to as_cpux) ─────────────────────────────────────
  assign clk_mux_s   = sc01_shift_i ? tck_i : gated_clk_s;
  assign gated_clk_s = clk_i && dr_cap_i;

  scan_cell sc01 (clk_mux_s, rst_i, sc01_shift_i, 1'b0, sc01_tdi_i, and_in01_s, sc01_01_s);
  scan_cell sc02 (clk_mux_s, rst_i, sc01_shift_i, 1'b0, sc01_01_s, and_in02_s, sc01_02_s);
  assign and_out_s = and_in01_s & and_in02_s;
  scan_cell sc03 (.tck_i(clk_mux_s), .trst_i(rst_i), .scan_shift_i(sc01_shift_i),
                  .data_i(and_out_s), .ser_i(sc01_02_s), .data_o(), .ser_o(sc01_03_s));
  scan_cell sc04 (.tck_i(clk_mux_s), .trst_i(rst_i), .scan_shift_i(sc01_shift_i),
                  .data_i(1'b0), .ser_i(sc01_03_s), .data_o(), .ser_o(sc01_tdo_o));

endmodule : cc_cpupipe
