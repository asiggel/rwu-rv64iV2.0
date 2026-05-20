// asCPUx_pipeline.sv - 5-stage pipelined RV64I CPU
`timescale 1ns/1ps
import as_pack::*;

module as_cpux_pipeline (
    input  logic                          clk_i,
    input  logic                          rst_i,
    input  logic                          tck_i,
    output logic [instr_width-1:0]        ir_o,
    input  logic                          dr_cap_i,
    output logic                          sc01_tdo_o,
    input  logic                          sc01_tdi_i,
    input  logic                          sc01_shift_i,
    input  logic                          sc01_clock_i,
    output logic [iaddr_width-1:0]        iBusAddr_o,
    input  logic [instr_width-1:0]        iBusDataRd_i,
    output logic [daddr_width-1:0]        dBusAddr_o,
    output logic [reg_width-1:0]          dBusDataWr_o,
    input  logic [reg_width-1:0]          dBusDataRd_i,
    output logic                          dBusWe_o,
    as_icache_if.cpu                      icpu_if,
    as_dcache_if.cpu                      dcpu_if,
    input  logic [irq_total_num_ext_c-1:0] irq_ext_i
);
  localparam int XLEN = reg_width;

  typedef struct packed {
    logic [iaddr_width-1:0] pc;
    logic [instr_width-1:0] instr;
    logic                   valid;
  } if_id_reg_t;

  typedef struct packed {
    logic [iaddr_width-1:0] pc;
    logic [reg_width-1:0]   rd1, rd2, imm_ext;
    logic [4:0]             rs1, rs2, rd;
    result_src_t            result_src;
    logic                   mem_wr, mem_rd, reg_wr, alu_src_b;
    mux_a_t                 alu_src_a;
    logic                   jump;
    imm_src_t               imm_src;
    alu_op_t                alu_op;
    br_op_t                 br_op;
    logic                   csr, valid;
  } id_ex_reg_t;

  typedef struct packed {
    logic [iaddr_width-1:0] pc_plus4;
    logic [reg_width-1:0]   alu_result, write_data, csr_data;
    logic [4:0]             rd;
    result_src_t            result_src;
    logic                   mem_wr, reg_wr, valid;  } ex_mem_reg_t;

  typedef struct packed {
    logic [reg_width-1:0]   read_data, alu_result, pc_plus4, csr_data;
    logic [4:0]             rd;
    result_src_t            result_src;
    logic                   reg_wr, valid;
  } mem_wb_reg_t;
  if_id_reg_t  if_id_r;
  id_ex_reg_t  id_ex_r;
  ex_mem_reg_t ex_mem_r;
  mem_wb_reg_t mem_wb_r;

  logic [iaddr_width-1:0] pc_r, pc_next_s, pc_plus4_s, pc_branch_s, pc_or_rs1_s;
  logic [reg_width-1:0]   reg_rd1_s, reg_rd2_s, imm_ext_s;
  result_src_t            result_src_s;
  logic                   mem_wr_s, mem_rd_s, reg_wr_s, alu_src_b_s, jump_s;
  mux_a_t                 alu_src_a_s;
  imm_src_t               imm_src_s;
  alu_op_t                alu_op_s;
  br_op_t                 br_op_s;
  logic                   csr_s;
  logic [reg_width-1:0]   alu_in_a_s, alu_src_a_mux_s, alu_src_b_mux_s;
  logic [reg_width-1:0]   alu_result_s, fwd_rs2_s, csr_data_ex_s, wb_result_s;
  logic                   branch_take_s;
  logic [1:0]             forward_a_s, forward_b_s;
  logic                   stall_if_s, stall_id_s, flush_if_id_s, flush_id_ex_s;
  logic                   control_taken_s, wb_reg_wr_s;
  logic [63:0]            csr_mepc_r, csr_mcause_r, csr_mtvec_r;
  logic [63:0]            csr_mstatus_r, csr_mie_r, csr_mip_r;
  
  logic                   irq_ext_sync1_r, irq_ext_sync2_r, irq_pending_s, trap_taken_s;
  logic                   gated_clk_s, clk_mux_s;
  logic                   and_in01_s, and_in02_s, and_out_s;
  logic                   sc01_01_s, sc01_02_s, sc01_03_s;

  assign csr_mstatus_mie_s  = csr_mstatus_r[3];
  
  assign irq_pending_s    = csr_mip_r[11] & csr_mie_r[11] & csr_mstatus_mie_s;
  assign control_taken_s  = (branch_take_s && (id_ex_r.br_op != BR_NONE)) || id_ex_r.jump;
  assign trap_taken_s     = id_ex_r.valid && irq_pending_s;
  assign ir_o             = {12'b0, 5'b0, 3'b0, ex_mem_r.rd, 7'b0};

  // PC
  assign pc_plus4_s  = pc_r + 64'd4;
  assign pc_or_rs1_s = id_ex_r.jump ? alu_in_a_s : id_ex_r.pc;
  assign pc_branch_s = pc_or_rs1_s + id_ex_r.imm_ext;

  always_comb begin
    if (trap_taken_s)         pc_next_s = {csr_mtvec_r[63:2], 2'b00};
    else if (control_taken_s) pc_next_s = pc_branch_s;
    else                      pc_next_s = pc_plus4_s;
  end

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) pc_r <= 64'h0;
    else if (!stall_if_s) pc_r <= pc_next_s;

  assign iBusAddr_o = pc_r;

  // IF/ID register
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      if_id_r <= '0; if_id_r.instr <= 32'h00000013;
    end else if (flush_if_id_s || trap_taken_s) begin
      if_id_r <= '0; if_id_r.instr <= 32'h00000013;
    end else if (!stall_if_s) begin
      if_id_r.pc    <= pc_r;
      if_id_r.instr <= iBusDataRd_i;
      if_id_r.valid <= 1'b1;
    end
  end

  // Register file
  as_regfile regfile (
    .clk_i(clk_i), .rst_i(rst_i),
    .we_i(wb_reg_wr_s),
    .raddr01_i(if_id_r.instr[19:15]),
    .raddr02_i(if_id_r.instr[24:20]),
    .waddr01_i(mem_wb_r.rd),
    .wdata01_i(wb_result_s),
    .rdata01_o(reg_rd1_s),
    .rdata02_o(reg_rd2_s)
  );

  // Decoder
  as_instr_decode decoder (
    .instr_opcode_i      (if_id_r.instr[6:0]),
    .instr_func3_i       (if_id_r.instr[14:12]),
    .instr_func7b5_i     (if_id_r.instr[30]),
    .take_i              (1'b0),
    .mux_resultSrc_o     (result_src_s),
    .en_dMemWr_o         (mem_wr_s),
    .en_dMemRd_o         (mem_rd_s),
    .mux_aluSrcB_o       (alu_src_b_s),
    .mux_aluSrcA_o       (alu_src_a_s),
    .en_regWr_o          (reg_wr_s),
    .mux_jump_o          (jump_s),
    .sel_immSrc_o        (imm_src_s),
    .alu_op_o            (alu_op_s),
    .br_op_o             (br_op_s),
    .trap_illegal_instr_o()  );

  assign csr_s = (if_id_r.instr[6:0] == 7'b1110011) && (if_id_r.instr[14:12] != 3'b000);

  // Immediate extension
  always_comb
    case (imm_src_s)
      IMM_I   : imm_ext_s = {{(XLEN-12){if_id_r.instr[31]}}, if_id_r.instr[31:20]};
      IMM_S   : imm_ext_s = {{(XLEN-12){if_id_r.instr[31]}}, if_id_r.instr[31:25], if_id_r.instr[11:7]};
      IMM_B   : imm_ext_s = {{(XLEN-12){if_id_r.instr[31]}}, if_id_r.instr[7], if_id_r.instr[30:25], if_id_r.instr[11:8], 1'b0};
      IMM_J   : imm_ext_s = {{(XLEN-20){if_id_r.instr[31]}}, if_id_r.instr[19:12], if_id_r.instr[20], if_id_r.instr[30:21], 1'b0};
      IMM_U   : imm_ext_s = {{(XLEN-32){if_id_r.instr[31]}}, if_id_r.instr[31:12], 12'b0};
      default : imm_ext_s = {XLEN{1'b0}};
    endcase

  // ID/EX register
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
    id_ex_r            <= '0;
      id_ex_r.alu_op     <= ALU_ADD;
      id_ex_r.br_op      <= BR_NONE;
      id_ex_r.alu_src_a  <= SRC_REGA;
      id_ex_r.result_src <= RES_ALU;
    end else if (flush_id_ex_s || trap_taken_s) begin
      id_ex_r            <= '0;
      id_ex_r.alu_op     <= ALU_ADD;
      id_ex_r.br_op      <= BR_NONE;
      id_ex_r.alu_src_a  <= SRC_REGA;
      id_ex_r.result_src <= RES_ALU;
    end else if (!stall_id_s) begin
      id_ex_r.pc         <= if_id_r.pc;
      id_ex_r.rd1        <= reg_rd1_s;
      id_ex_r.rd2        <= reg_rd2_s;
      id_ex_r.imm_ext    <= imm_ext_s;
      id_ex_r.rs1        <= if_id_r.instr[19:15];
      id_ex_r.rs2        <= if_id_r.instr[24:20];
      id_ex_r.rd         <= if_id_r.instr[11:7];
      id_ex_r.result_src <= result_src_s;
      id_ex_r.mem_wr     <= mem_wr_s;
      id_ex_r.mem_rd     <= mem_rd_s;
      id_ex_r.reg_wr     <= reg_wr_s;
      id_ex_r.alu_src_b  <= alu_src_b_s;
      id_ex_r.alu_src_a  <= alu_src_a_s;
      id_ex_r.jump       <= jump_s;
      id_ex_r.imm_src    <= imm_src_s;
      id_ex_r.alu_op     <= alu_op_s;
      id_ex_r.br_op      <= br_op_s;
      id_ex_r.csr        <= csr_s;
      id_ex_r.valid      <= if_id_r.valid;
    end
  end
  // Forwarding muxes
  always_comb case (forward_a_s)
    2'b10:   alu_in_a_s = ex_mem_r.alu_result;
    2'b01:   alu_in_a_s = wb_result_s;
    default: alu_in_a_s = id_ex_r.rd1;
  endcase

  always_comb case (forward_b_s)
    2'b10:   fwd_rs2_s = ex_mem_r.alu_result;
    2'b01:   fwd_rs2_s = wb_result_s;
    default: fwd_rs2_s = id_ex_r.rd2;
  endcase

  always_comb case (id_ex_r.alu_src_a)
    SRC_PC  : alu_src_a_mux_s = id_ex_r.pc;
    SRC_ZERO: alu_src_a_mux_s = {XLEN{1'b0}};
    default : alu_src_a_mux_s = alu_in_a_s;
  endcase

  assign alu_src_b_mux_s = id_ex_r.alu_src_b ? id_ex_r.imm_ext : fwd_rs2_s;

  as_alu alu (
    .data01_i(alu_src_a_mux_s), .data02_i(alu_src_b_mux_s),
    .alu_op_i(id_ex_r.alu_op),  .aluResult_o(alu_result_s)
  );

  as_alu_branch alu_br (
    .data01_i(alu_in_a_s), .data02_i(fwd_rs2_s),
    .br_op_i(id_ex_r.br_op), .take_o(branch_take_s)
  );

  always_comb begin
    csr_data_ex_s = 64'h0;
    if (id_ex_r.csr)
      case (id_ex_r.imm_ext[11:0])
        12'h300: csr_data_ex_s = csr_mstatus_r;
        12'h304: csr_data_ex_s = csr_mie_r;
        12'h305: csr_data_ex_s = csr_mtvec_r;
        12'h341: csr_data_ex_s = csr_mepc_r;
        12'h342: csr_data_ex_s = csr_mcause_r;
        12'h344: csr_data_ex_s = csr_mip_r;
        default: csr_data_ex_s = 64'h0;
      endcase
  end

  // EX/MEM register
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i || trap_taken_s) begin
      ex_mem_r <= '0; ex_mem_r.result_src <= RES_ALU;
    end else begin
      ex_mem_r.pc_plus4   <= id_ex_r.pc + 64'd4;
      ex_mem_r.alu_result <= alu_result_s;
      ex_mem_r.write_data <= fwd_rs2_s;
      ex_mem_r.csr_data   <= csr_data_ex_s;
      ex_mem_r.rd         <= id_ex_r.rd;
      ex_mem_r.result_src <= id_ex_r.result_src;
      ex_mem_r.mem_wr     <= id_ex_r.mem_wr;
      ex_mem_r.reg_wr     <= id_ex_r.reg_wr;
      ex_mem_r.valid      <= id_ex_r.valid;
    end
  end

  // MEM stage
  assign dBusAddr_o   = ex_mem_r.alu_result;
  assign dBusDataWr_o = ex_mem_r.write_data;
  assign dBusWe_o     = ex_mem_r.mem_wr && ex_mem_r.valid;

  // MEM/WB register
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      mem_wb_r <= '0; mem_wb_r.result_src <= RES_ALU;
    end else begin
      mem_wb_r.read_data  <= dBusDataRd_i;
      mem_wb_r.alu_result <= ex_mem_r.alu_result;
      mem_wb_r.pc_plus4   <= ex_mem_r.pc_plus4;
      mem_wb_r.csr_data   <= ex_mem_r.csr_data;
      mem_wb_r.rd         <= ex_mem_r.rd;
      mem_wb_r.result_src <= ex_mem_r.result_src;
      mem_wb_r.reg_wr     <= ex_mem_r.reg_wr;
      mem_wb_r.valid      <= ex_mem_r.valid;
    end
  end

  // WB stage
  always_comb case (mem_wb_r.result_src)
    RES_MEM : wb_result_s = mem_wb_r.read_data;
    RES_PC4 : wb_result_s = mem_wb_r.pc_plus4;
    RES_CSR : wb_result_s = mem_wb_r.csr_data;
    default : wb_result_s = mem_wb_r.alu_result;
  endcase

  assign wb_reg_wr_s = mem_wb_r.reg_wr && mem_wb_r.valid &&
                       (mem_wb_r.rd != 5'b0) && !trap_taken_s;

  // Forwarding unit
  as_forwarding_unit fwd_unit (
    .id_ex_rs1_i    (id_ex_r.rs1),
    .id_ex_rs2_i    (id_ex_r.rs2),
    .ex_mem_rd_i    (ex_mem_r.rd),
    .ex_mem_regwr_i (ex_mem_r.reg_wr && ex_mem_r.valid),
    .mem_wb_rd_i    (mem_wb_r.rd),
    .mem_wb_regwr_i (mem_wb_r.reg_wr && mem_wb_r.valid),
    .forward_a_o    (forward_a_s),
    .forward_b_o    (forward_b_s)
  );

  // Hazard unit
  as_hazard_unit hzd_unit (
    .if_id_rs1_i    (if_id_r.instr[19:15]),
    .if_id_rs2_i    (if_id_r.instr[24:20]),
    .id_ex_rd_i     (id_ex_r.rd),
    .id_ex_memrd_i  (id_ex_r.mem_rd),
    .id_ex_csr_i    (id_ex_r.csr),
    .branch_taken_i (branch_take_s && (id_ex_r.br_op != BR_NONE)),
    .jump_i         (id_ex_r.jump),
    .stall_if_o     (stall_if_s),
    .stall_id_o     (stall_id_s),
    .flush_if_id_o  (flush_if_id_s),
    .flush_id_ex_o  (flush_id_ex_s)
  );

  // CSR registers
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) begin irq_ext_sync1_r <= 0; irq_ext_sync2_r <= 0; end
    else begin irq_ext_sync1_r <= irq_ext_i[7]; irq_ext_sync2_r <= irq_ext_sync1_r; end

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) csr_mip_r <= 64'h0;
    else        csr_mip_r[11] <= irq_ext_sync2_r;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) csr_mie_r <= 64'h0000000000000800;
    else if (id_ex_r.valid && id_ex_r.csr && (id_ex_r.imm_ext[11:0] == 12'h304))
      csr_mie_r <= alu_in_a_s;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) csr_mstatus_r <= 64'h0000000000001808;
    else if (trap_taken_s) begin
      csr_mstatus_r[7] <= csr_mstatus_mie_s;
      csr_mstatus_r[3] <= 1'b0;
    end else if (id_ex_r.valid && id_ex_r.csr && (id_ex_r.imm_ext[11:0] == 12'h300))
      csr_mstatus_r <= alu_in_a_s;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) csr_mepc_r <= 64'h0;
    else if (trap_taken_s) csr_mepc_r <= id_ex_r.pc;
    else if (id_ex_r.valid && id_ex_r.csr && (id_ex_r.imm_ext[11:0] == 12'h341))
      csr_mepc_r <= alu_in_a_s;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) csr_mtvec_r <= 64'h0000000000007F00;
    else if (id_ex_r.valid && id_ex_r.csr && (id_ex_r.imm_ext[11:0] == 12'h305))
      csr_mtvec_r <= alu_in_a_s;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) csr_mcause_r <= 64'h0;
    else if (trap_taken_s) csr_mcause_r <= {1'b1, 63'd11};

  // Cache tie-off
  assign icpu_if.ic_addr  = '0;
  assign icpu_if.ic_req   = 1'b0;
  assign icpu_if.ic_flush = 1'b0;
  assign dcpu_if.dc_addr  = '0;
  assign dcpu_if.dc_req   = 1'b0;
  assign dcpu_if.dc_wr    = 1'b0;
  assign dcpu_if.dc_size  = '0;
  assign dcpu_if.dc_wdata = '0;
  assign dcpu_if.dc_wstrb = '0;
  assign dcpu_if.dc_flush = 1'b0;

  // Scan chain
  assign clk_mux_s   = sc01_shift_i ? tck_i : gated_clk_s;
  assign gated_clk_s = clk_i && dr_cap_i;
  scan_cell sc01(clk_mux_s,rst_i,sc01_shift_i,1'b0,    sc01_tdi_i, and_in01_s,sc01_01_s);
  scan_cell sc02(clk_mux_s,rst_i,sc01_shift_i,1'b0,    sc01_01_s,  and_in02_s,sc01_02_s);
  assign and_out_s = and_in01_s & and_in02_s;
  scan_cell sc03(clk_mux_s,rst_i,sc01_shift_i,and_out_s,sc01_02_s,,sc01_03_s);
  scan_cell sc04(clk_mux_s,rst_i,sc01_shift_i,1'b0,    sc01_03_s,, sc01_tdo_o);

endmodule : as_cpux_pipeline