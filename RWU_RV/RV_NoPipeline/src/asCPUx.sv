
// asCPUx.sv
`timescale 1ns/1ps

import as_pack::*;

module as_cpux #(parameter logic [63:0] HART_ID = 64'd0) // -> mhartid
              (input  logic                         clk_i,
               input  logic                          rst_i,
               input  logic tck_i,
               output logic [instr_width-1:0]        ir_o,         // needed for byte-select logic in D-Mem
               input  logic dr_cap_i,
              // Scan Chain
               output logic                          sc01_tdo_o,   // scan: serial out
               input  logic                          sc01_tdi_i,   // scan: serial in
               input  logic                          sc01_shift_i, // scan: shift enable
               /* verilator lint_off UNUSEDSIGNAL */ // scan clock received for interface compatibility; not used in current scan chain implementation
               input  logic                          sc01_clock_i,
               /* verilator lint_on UNUSEDSIGNAL */ // scan: clock enabe
               // Instruction bus (legacy flat BPI)
               output logic [iaddr_width-1:0]        iBusAddr_o,     // I-Bus: address
               input  logic [instr_width-1:0]        iBusDataRd_i,   // I-Bus: data
               // Data bus (legacy flat BPI)
               output logic [daddr_width-1:0]        dBusAddr_o,     // address for dmem
               output logic [reg_width-1:0]          dBusDataWr_o,   // data to dmem
               input  logic [reg_width-1:0]          dBusDataRd_i,   // data from dmem
               output logic                          dBusWe_o,       // write enable fo dmem
               // Cache interfaces (disabled: tied to 0 until as_top_mem connects asMemTop)
               as_icache_if.cpu                      icpu_if,
               as_dcache_if.cpu                      dcpu_if,
               // IRQ
               /* verilator lint_off UNUSEDSIGNAL */ // only bit 7 (ICU output -> mip.MEIP) implemented; lower bits reserved
               input logic [irq_total_num_ext_c-1:0] irq_ext_i, // External interrupts, irq_ext_i[7] = ICU0
               /* verilator lint_on UNUSEDSIGNAL */
               input logic                           irq_m_soft_i,  // CLINT msip  -> mip.MSIP
               input logic                           irq_m_timer_i  // CLINT mtip  -> mip.MTIP
              );

  localparam int XLEN = reg_width;

  // Umbau
  logic aluSrcB_s,regWr_s,jump_s,take_s; //,PCsrc_s;
  mux_a_t                    aluSrcA_s;
  result_src_t               resultSrcx_s;
  imm_src_t                  immSrcx_s;
  alu_op_t                   aluSela_s;
  br_op_t                    aluSelb_s;

  // instruction
  logic [instr_width-1:0]     iBusDataRd_s; // data out from imem
  logic [iaddr_width-1:0]     iBusAddr_s;   // address for imem
  logic [iaddr_width-1:0]     PC_instr_r;   // PC of instruction currently in IR

  // data
  logic [reg_width-1:0]       dBusDataRd_s; // data out from dmem
  logic [reg_width-1:0]       dBusDataWr_s; // data in to dmem
  logic [daddr_width-1:0]     dBusAddr_s;   // address for dmem
  logic                       dMemRd_s;     // read enable for dmem
  logic                       dMemWr_s;     // write enable for dmem

  // PC
  logic [iaddr_width-1:0] PC_link_s; // JAL/JALR return address = PC_instr_r + 4
  logic [iaddr_width-1:0] PCbr_s;    // branch/jump target
  logic	[iaddr_width-1:0] PCorRS1_s;

  // Immediate extention
  logic [reg_width-1:0] immExt_s;
  // Register file
  logic [reg_width-1:0] srcA_s, regA_s;
  logic [reg_width-1:0] srcB_s;

  // D-Mem
  logic [reg_width-1:0] result_s;
  // ALU
  logic [reg_width-1:0]	aluRes_s, aluCalcRes_s;

  logic	and_in01_s;
  logic	sc01_01_s;
  logic	sc01_02_s;
  logic	sc01_03_s;
  logic	and_in02_s;
  logic	and_out_s;

  //IRQ
  logic [reg_width-1:0] csr_data_s;
  logic [reg_width-1:0] csr_wdata_s;
  logic [reg_width-1:0] regfile_data_w_s;
  
  logic	regWr_final_s;
  
  logic [instr_width-1:0] ir_s; // instruction register
  logic	trap_illegal_instrx_s;

  // FSM for pipeline timing
  typedef enum logic [1:0] {FETCH0_ST, FETCH1_ST, EXEC_ST, EXECLD_ST} statetype_t;
  statetype_t state_s, nextstate_s;
  logic fetch0_phase_s;   // address to I-Mem
  logic fetch1_phase_s;   // data from I-Mem
  logic exec_phase_s;     // IR ausführen
  logic execld_phase_s;     // IR ausführen
    
  logic instr_commit_s;

  logic load_pending_s;
  
  logic is_mret_s;          // Current instruction is MRET
  logic is_ecall_s;         // Current instruction is ECALL
  logic is_ebreak_s;        // Current instruction is EBREAK
  logic is_wfi_s;           // Current instruction is WFI
  logic is_csr_s;           // Current instruction is csrrw/s/c[i]
  logic [iaddr_width-1:0] PC_s;

  logic [6:0] opcode_s;
  logic trap_illegal_s;
  logic sys_illegal_s;      // illegal SYSTEM instruction, decided by the trap unit

  // Traps (see "Precise traps" below)
  logic                   misal_pc_s;   // taken branch/jump to a non-word address
  logic                   misal_ld_s;
  logic                   misal_st_s;
  logic [iaddr_width-1:0] PCtarget_s;   // branch/jump target, JALR bit 0 cleared
  logic                   exc_s;        // instruction in IR raises an exception
  logic [3:0]             exc_cause_s;
  logic [63:0]            exc_tval_s;
  logic                   exc_r;
  logic [3:0]             exc_cause_r;
  logic [63:0]            exc_tval_r;
  logic [iaddr_width-1:0] npc_r;        // address of the next instruction in program order
  logic [iaddr_width-1:0] fetch_pc_s;   // address fetched in FETCH0_ST
  logic [iaddr_width-1:0] trap_pc_s;    // -> mepc
  logic                   irq_pending_s;
  logic                   irq_take_s;
  logic                   exc_take_s;
  logic                   mret_s;
  logic                   trap_s;
  logic                   wfi_wake_s;
  logic                   wfi_stall_s;
  logic                   csr_we_s;
  logic                   instret_s;
  logic [63:0]            trap_vec_s;
  logic [63:0]            mepc_s;

  logic	gated_clk_s;
  logic	clk_mux_s;
  
  

  assign ir_o = ir_s; // instruction register

  //--------------------------------------------
  // Master BPI Instruction Bus
  //--------------------------------------------
  assign iBusAddr_o = iBusAddr_s;
  assign iBusDataRd_s = iBusDataRd_i;

  //--------------------------------------------
  // Master BPI Data Bus
  //--------------------------------------------
  //assign dbpi_req_s = 1'b1; // kann weg!!

  // A store that traps must not reach memory (precise exception).
  assign dBusWe_o     = dMemWr_s && exec_phase_s && !exc_s;
  assign dBusAddr_o   = dBusAddr_s;
  assign dBusDataWr_o = dBusDataWr_s;
  assign dBusDataRd_s = dBusDataRd_i;

  //--------------------------------------------
  // PC, Program Counter and IR (Instruction Register)
  //--------------------------------------------
  // FETCH0_ST fetches the next instruction: the trap vector, mepc (MRET) or
  // the next instruction in program order. All three are known before the
  // fetch, so no wrong-path instruction ever enters IR.
  always_comb
  begin
    if (trap_s)
      fetch_pc_s = trap_vec_s;
    else if (mret_s)
      fetch_pc_s = mepc_s;
    else
      fetch_pc_s = npc_r;
  end

  assign iBusAddr_s = fetch0_phase_s ? fetch_pc_s : PC_s;
  
  //--------------------------------------------
  // ... PC itself:
  // PC is always one pipeline slot AHEAD of the instruction in IR:
  //   PC_s = PC_instr_r + 4 during FETCH1/EXEC.
  // It is advanced in each FETCH0_ST.
  //--------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i)
      PC_s <= 64'h0000000000000000;
    else
    begin
      if(fetch0_phase_s)
        PC_s <= fetch_pc_s + 64'd4;
    end
  end

  // Captures the address of the instruction being fetched in FETCH0_ST.
  // Used as branch/jump base, for AUIPC and as mepc of an exception.
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i)
      PC_instr_r <= '0;
    else if(fetch0_phase_s)
      PC_instr_r <= iBusAddr_s;
  end

  //===========================================
  // Instruction Register
  //===========================================
  // IR keeps the committed instruction through FETCH0_ST: the trap/MRET
  // decision of that cycle is taken on it.
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i)
      ir_s <= 32'h00000013;  // NOP
    else
      if(fetch1_phase_s)
        ir_s <= iBusDataRd_s;
  end
  
  //--------------------------------------------
  // Establishes working phases because of PC-IR pipeline (nothing more than a simple 3-counter so far)
  //
  // Stall-FSM 1: nextstate CLC
  always_comb 
  begin
    nextstate_s = state_s;
    case(state_s)
      FETCH0_ST  : nextstate_s = FETCH1_ST;
      FETCH1_ST  : nextstate_s = EXEC_ST;
      EXEC_ST    : if(load_pending_s)
                     nextstate_s = EXECLD_ST;
                   else if(wfi_stall_s)
                     nextstate_s = EXEC_ST;
                   else
                     nextstate_s = FETCH0_ST;
      EXECLD_ST  : nextstate_s = FETCH0_ST;
      default    : nextstate_s = FETCH0_ST;
    endcase
  end // always_comb
  
  // Stall-FSM 2: delay
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      state_s <= FETCH0_ST;
    else
      state_s <= nextstate_s;
  end
  
  // Stall-FSM 3: output CLC
  assign fetch0_phase_s = (state_s == FETCH0_ST) ? 1 : 0;
  assign fetch1_phase_s = (state_s == FETCH1_ST) ? 1 : 0;
  assign exec_phase_s   = (state_s == EXEC_ST)   ? 1 : 0;
  assign execld_phase_s = (state_s == EXECLD_ST)   ? 1 : 0;
  //--------------------------------------------
  
 
  
  //--------------------------------------------
  // ... indicates, when a regular instruction should be executed
  //--------------------------------------------
  assign instr_commit_s = (exec_phase_s && !load_pending_s && !wfi_stall_s) || execld_phase_s;
  // Load detection
  assign load_pending_s = (opcode_s == 7'b0000011) && exec_phase_s;
  
  //--------------------------------------------
  // Adder +4 for the link address
  //--------------------------------------------
  assign PC_link_s = PC_instr_r + 64'd4;  // spec-correct return address for JAL/JALR

  //--------------------------------------------
  // Mux for jumps of jalr instruction or normal branches.
  //         - pc_o   : jalr
  //         - regA_s : normal branch
  //--------------------------------------------
  assign PCorRS1_s = jump_s ? regA_s : PC_instr_r;

  //--------------------------------------------
  // Adder for the branch targets
  //--------------------------------------------
  assign PCbr_s = PCorRS1_s + immExt_s;

  //--------------------------------------------
  // Mux for the PC, either +4 or branch target
  //--------------------------------------------
  //assign PCnext_mux_s = PCsrc_s ? PCbr_s : PCp4_s;

  //--------------------------------------------
  // Register file
  //--------------------------------------------
  // CSR or result
  assign regfile_data_w_s = result_s;
  assign regWr_final_s    = regWr_s && !exc_s && instr_commit_s;
  as_regfile regfile (.clk_i(clk_i),
                      .rst_i(rst_i),
                      .we_i(regWr_final_s),
                      .raddr01_i(ir_s[19:15]),
                      .raddr02_i(ir_s[24:20]),
                      .waddr01_i(ir_s[11:7]),
                      .wdata01_i(regfile_data_w_s),
                      .rdata01_o(regA_s),
                      .rdata02_o(dBusDataWr_s)
                     );

  //--------------------------------------------
  // Immediate generation
  //--------------------------------------------
  always_comb
    case(immSrcx_s)
      IMM_I    : immExt_s = {{(XLEN-12){ir_s[31]}},ir_s[31:20]}; // I-type: sign ext, immediate (12 b)
      IMM_S    : immExt_s = {{(XLEN-12){ir_s[31]}},ir_s[31:25],ir_s[11:7]}; // S-type: sign ext, immediate1 (7 b), immediate2 (5 b)
      IMM_B    : immExt_s = {{(XLEN-12){ir_s[31]}},ir_s[7],ir_s[30:25],ir_s[11:8],1'b0}; // B-type: sign ext, imm1 (1 b), imm2 (6 b), imm3 (4 b), *2
      IMM_J    : immExt_s = {{(XLEN-20){ir_s[31]}},ir_s[19:12],ir_s[20],ir_s[30:21],1'b0}; // J-type: sign ext, imm1 (8 b), imm2 (1 b), imm3 (10 b), *2
      IMM_U    : immExt_s = {{(XLEN-32){ir_s[31]}}, ir_s[31:12], 12'b0};
      IMM_NONE : immExt_s = {reg_width{1'b0}};
      default  : immExt_s = {reg_width{1'b0}};
    endcase

  //--------------------------------------------
  // ALU: input mux for regB or immediate
  //--------------------------------------------
  assign srcB_s = aluSrcB_s ? immExt_s : dBusDataWr_s;

  //--------------------------------------------
  // ALU: input mux for regA or PC
  //--------------------------------------------
  always_comb
    case(aluSrcA_s)
      SRC_REGA    : srcA_s = regA_s;
      SRC_PC      : srcA_s = PC_instr_r;
      SRC_ZERO    : srcA_s = {reg_width{1'b0}};
      default     : srcA_s = regA_s;
    endcase // case (aluSrcA_s)
  
  //--------------------------------------------
  // ALU
  //--------------------------------------------
  as_alu alua (.data01_i(srcA_s),
               .data02_i(srcB_s),
               .alu_op_i(aluSela_s),
               .aluResult_o(aluRes_s)
              );
  assign dBusAddr_s   = aluRes_s;
  assign aluCalcRes_s = aluRes_s;

  as_alu_branch alub (.data01_i(srcA_s),
                      .data02_i(srcB_s),
                      .br_op_i(aluSelb_s),
                      .take_o(take_s)
                     );

  //--------------------------------------------
  // Mux for aluResult, dmem or PC+4 to register file
  //--------------------------------------------
  always_comb
    case(resultSrcx_s)
      RES_ALU    : result_s = aluCalcRes_s;
      RES_MEM    : result_s = dBusDataRd_s;
      RES_PC4    : result_s = PC_link_s;
      RES_CSR    : result_s = csr_data_s;
      default    : result_s = {reg_width{1'b0}};
    endcase
  
  //--------------------------------------------
  // Instruction decoder
  //--------------------------------------------
  as_instr_decode control (.instr_opcode_i(ir_s[6:0]),
                           .instr_func3_i(ir_s[14:12]),
                           .instr_func7b5_i(ir_s[30]),
                           .take_i(take_s),                 // branch taken
                           .mux_resultSrc_o(resultSrcx_s),  // sel for mux which writes data to the RegFile
                           .en_dMemWr_o(dMemWr_s),          // D-Mem write enable
                           .en_dMemRd_o(dMemRd_s),          // D-Mem read ensable, not needed by the D-Mem but as control for other logic
                           .mux_aluSrcB_o(aluSrcB_s),       // sel for mux which writes data to the ALU B entry
                           .mux_aluSrcA_o(aluSrcA_s),       // sel for mux which writes data to the ALU A entry
                           .en_regWr_o(regWr_s),            // RegFile write enable
                           .mux_jump_o(jump_s),             // sel for mux which writes the jump target address
                           .sel_immSrc_o(immSrcx_s),        // sel for the correct immediate generation
                           .alu_op_o(aluSela_s),            // selects the arithmetic ALU operation
                           .br_op_o(aluSelb_s),             // selects the branch ALU operation
                           .trap_illegal_instr_o(trap_illegal_instrx_s) // indicator for an illegal instruction
                      );
  
  //--------------------------------------------
  // IRQ, exceptions and CSRs
  //--------------------------------------------
  // Precise traps:
  //  - An exception is detected while its instruction executes (EXEC_ST or
  //    EXECLD_ST). The instruction is suppressed (no register write, no
  //    store, no CSR write) and the trap is taken in the next FETCH0_ST with
  //    mepc = address of the faulting instruction.
  //  - An interrupt is taken in FETCH0_ST, between two instructions: the
  //    instruction in IR has completed, the next one (npc_r) is not fetched
  //    yet, so mepc = npc_r.
  //  - MRET redirects in FETCH0_ST as well, so no look-ahead decode of the
  //    prefetched instruction is needed.

  assign opcode_s = ir_s[6:0];

  assign is_mret_s   = (ir_s == 32'h30200073);
  assign is_ecall_s  = (ir_s == 32'h00000073);
  assign is_ebreak_s = (ir_s == 32'h00100073);
  assign is_wfi_s    = (ir_s == 32'h10500073);
  assign is_csr_s    = (opcode_s == 7'b1110011) && (ir_s[13:12] != 2'b00);

  assign trap_illegal_s = trap_illegal_instrx_s || sys_illegal_s;

  // JALR clears bit 0 of its target; with IALIGN = 32 bit 1 must then be 0.
  assign PCtarget_s = jump_s ? {PCbr_s[iaddr_width-1:1], 1'b0} : PCbr_s;
  assign misal_pc_s = take_s && (PCtarget_s[1:0] != 2'b00);

  // funct3[1:0] is the access size for loads and stores: B, H, W, D
  always_comb
  begin
    misal_ld_s = 1'b0;
    misal_st_s = 1'b0;
    case (ir_s[13:12])
      2'b01:
      begin
        misal_ld_s = dMemRd_s && dBusAddr_s[0];
        misal_st_s = dMemWr_s && dBusAddr_s[0];
      end
      2'b10:
      begin
        misal_ld_s = dMemRd_s && (dBusAddr_s[1:0] != 2'b00);
        misal_st_s = dMemWr_s && (dBusAddr_s[1:0] != 2'b00);
      end
      2'b11:
      begin
        misal_ld_s = dMemRd_s && (dBusAddr_s[2:0] != 3'b000);
        misal_st_s = dMemWr_s && (dBusAddr_s[2:0] != 3'b000);
      end
      default: ;
    endcase
  end

  always_comb
  begin
    exc_s       = 1'b1;
    exc_cause_s = 4'd0;
    exc_tval_s  = 64'd0;
    if (trap_illegal_s)
    begin
      exc_cause_s = 4'd2;
      exc_tval_s  = {32'b0, ir_s};
    end
    else if (misal_pc_s)
    begin
      exc_cause_s = 4'd0;
      exc_tval_s  = PCtarget_s;
    end
    else if (misal_ld_s)
    begin
      exc_cause_s = 4'd4;
      exc_tval_s  = dBusAddr_s;
    end
    else if (misal_st_s)
    begin
      exc_cause_s = 4'd6;
      exc_tval_s  = dBusAddr_s;
    end
    else if (is_ecall_s)
      exc_cause_s = 4'd11;
    else if (is_ebreak_s)
      exc_cause_s = 4'd3;
    else
      exc_s = 1'b0;
  end

  assign wfi_stall_s = exec_phase_s && is_wfi_s && !wfi_wake_s;
  assign csr_we_s    = instr_commit_s && is_csr_s && !exc_s;
  assign csr_wdata_s = ir_s[14] ? {{(reg_width-5){1'b0}}, ir_s[19:15]} : regA_s;
  assign instret_s   = instr_commit_s && !exc_s;

  // Decisions of FETCH0_ST, taken on the instruction that just committed
  assign irq_take_s = fetch0_phase_s && irq_pending_s && !exc_r && !is_mret_s;
  assign exc_take_s = fetch0_phase_s && exc_r;
  assign trap_s     = exc_take_s || irq_take_s;
  assign mret_s     = fetch0_phase_s && is_mret_s && !exc_r;
  assign trap_pc_s  = exc_r ? PC_instr_r : npc_r;

  // Registered at commit: in FETCH0_ST a just-written rd may already have
  // changed the operands, so exc_s/take_s must not be re-evaluated there.
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
    begin
      exc_r       <= 1'b0;
      exc_cause_r <= 4'd0;
      exc_tval_r  <= 64'd0;
    end
    else if (instr_commit_s)
    begin
      exc_r       <= exc_s;
      exc_cause_r <= exc_cause_s;
      exc_tval_r  <= exc_tval_s;
    end
    else if (fetch0_phase_s)
      exc_r       <= 1'b0;
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      npc_r <= '0;
    else if (instr_commit_s)
      npc_r <= take_s ? PCtarget_s : PC_s;
  end

  cc_trap_csr #(.HART_ID(HART_ID), .MTVEC_RST(64'h0000_0000_0000_7F00))
  trap_csr (.clk_i        (clk_i),
            .rst_i        (rst_i),
            .irq_m_ext_i  (irq_ext_i[7]),
            .irq_m_soft_i (irq_m_soft_i),
            .irq_m_timer_i(irq_m_timer_i),
            .rd_instr_i   (ir_s),
            .rd_data_o    (csr_data_s),
            .rd_illegal_o (sys_illegal_s),
            .wr_en_i      (csr_we_s),
            .wr_instr_i   (ir_s),
            .wr_data_i    (csr_wdata_s),
            .exc_i        (exc_take_s),
            .exc_cause_i  (exc_cause_r),
            .exc_tval_i   (exc_tval_r),
            .irq_take_i   (irq_take_s),
            .trap_pc_i    (trap_pc_s),
            .mret_i       (mret_s),
            .instret_i    (instret_s),
            .irq_pending_o(irq_pending_s),
            .wfi_wake_o   (wfi_wake_s),
            .trap_vec_o   (trap_vec_s),
            .mepc_o       (mepc_s)
           );

  // 2Do: - mret einbauen                                (done)
  //      - PC-Mux: ISR-Zieladresse einbauen             (done)
  //      - die restlichen csrxx Instruktionen einbauen  (done)
  //      - mehr IRQ-Quellen, Exceptions ud Traps        (done)
  //      - Assembler-Testprogramm schreiben             (done)
  //      - External IRQ programmable: level, rising, falling edge

  //--------------------------------------------
  // Cache interfaces – disabled, tied to 0
  // Active low-level: CPU drives addr/req/wr to 0; cache responses unused.
  //--------------------------------------------
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

  //--------------------------------------------
  // Test Scan Chain
  //--------------------------------------------
  assign clk_mux_s = (sc01_shift_i == 1) ? tck_i : gated_clk_s; // Must be a real clock mux!
  assign gated_clk_s = clk_i && dr_cap_i;                       // Must be a real clock gate!
  
  //assign clk_mux_s = ~tck_i; // !!! Must be a real clock mux!!!
  scan_cell sc01 (clk_mux_s, rst_i, sc01_shift_i, 1'b0, sc01_tdi_i, and_in01_s, sc01_01_s);
  scan_cell sc02 (clk_mux_s, rst_i, sc01_shift_i, 1'b0, sc01_01_s, and_in02_s, sc01_02_s);
  assign and_out_s = and_in01_s & and_in02_s;
  scan_cell sc03 (.tck_i(clk_mux_s), .trst_i(rst_i), .scan_shift_i(sc01_shift_i),
                  .data_i(and_out_s), .ser_i(sc01_02_s), .data_o(), .ser_o(sc01_03_s));
  scan_cell sc04 (.tck_i(clk_mux_s), .trst_i(rst_i), .scan_shift_i(sc01_shift_i),
                  .data_i(1'b0), .ser_i(sc01_03_s), .data_o(), .ser_o(sc01_tdo_o));

endmodule : as_cpux

