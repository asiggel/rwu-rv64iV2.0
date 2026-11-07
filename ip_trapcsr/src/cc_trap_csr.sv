// cc_trap_csr.sv
`timescale 1ns/1ps

/*
cc_trap_csr - machine-mode CSRs, interrupt and trap control (RV64, M-mode only)
================================================================================

Shared by as_cpux (RV_NoPipeline) and cc_cpupipefwd (RV_PipelineCacheFwd).
The core decides WHEN a trap is taken (its precise-trap point); this block
holds the architectural state and decides WHAT happens.

Implemented CSRs (all others raise an illegal-instruction exception)
  Addr   Name        Access  Notes
  0x300  mstatus     rw      only MIE[3], MPIE[7] writable; MPP[12:11] = 11 fixed
  0x301  misa        r(WARL) RV64I: MXL = 2, extension I; writes ignored
  0x304  mie         rw      MSIE[3], MTIE[7], MEIE[11]; other bits 0
  0x305  mtvec       rw      MODE[0]: 0 = direct, 1 = vectored; MODE[1] = 0
  0x340  mscratch    rw
  0x341  mepc        rw      mepc[1:0] = 0 (IALIGN = 32)
  0x342  mcause      rw      bit 63 and code[3:0] stored (WLRL)
  0x343  mtval       rw
  0x344  mip         r       MSIP[3], MTIP[7], MEIP[11]: levels of the inputs
  0xB00  mcycle      rw      counts every clk_i cycle
  0xB02  minstret    rw      counts instret_i
  0xC00  cycle       r       read-only shadow of mcycle
  0xC02  instret     r       read-only shadow of minstret
  0xF11  mvendorid   r       0 (non-commercial)
  0xF12  marchid     r       0
  0xF13  mimpid      r       0
  0xF14  mhartid     r       parameter HART_ID
  0xF15  mconfigptr  r       0

Interrupts (level-sensitive, as required by CLINT and PLIC)
  irq_m_ext_i   -> mip.MEIP, mcause = 0x8000_0000_0000_000B
  irq_m_soft_i  -> mip.MSIP, mcause = 0x8000_0000_0000_0003 (CLINT msip)
  irq_m_timer_i -> mip.MTIP, mcause = 0x8000_0000_0000_0007 (CLINT mtip)
  Priority if several are pending: MEI > MSI > MTI.
  The inputs pass a 2-FF synchronizer, so they may come from another clock
  domain (e.g. a CLINT on the bus clock).

Core interface
  Read port   rd_instr_i: the SYSTEM instruction that reads its CSR now.
              rd_data_o is the old CSR value (for rd), rd_illegal_o flags an
              illegal SYSTEM instruction (unknown CSR, write to a read-only
              CSR, reserved funct3, unknown funct3 = 000 encoding).
  Write port  wr_en_i: a CSR instruction commits without trap.
              wr_data_i: the operand (rs1 value or zero-extended uimm).
              csrrs/csrrc with rs1 = x0 (uimm = 0) do not write, so a read of
              minstret does not disturb counting.
  Trap port   exc_i + exc_cause_i/exc_tval_i: synchronous exception.
              irq_take_i: the core takes the pending interrupt now; only
              allowed while irq_pending_o = 1. It has priority over exc_i,
              because an interrupt is taken before the instruction executes.
              trap_pc_i: written to mepc.
              trap_vec_o: target address for the trap of this cycle.
              mret_i: MRET commits; the core jumps to mepc_o.
  wfi_wake_o  an enabled interrupt is pending, independent of mstatus.MIE
              (WFI resumes on this even if interrupts are globally off).

Rule for the core (precise traps): an instruction that traps must not have
changed any architectural state (register, CSR, memory) - and an interrupt
may only be taken on an instruction that has not yet done so.
*/

module cc_trap_csr #(parameter logic [63:0] HART_ID   = 64'd0,
                     parameter logic [63:0] MTVEC_RST = 64'h0000_0000_0000_7F00
                    )
                    ( input  logic        clk_i,
                      input  logic        rst_i,
                      // interrupt request levels
                      input  logic        irq_m_ext_i,
                      input  logic        irq_m_soft_i,
                      input  logic        irq_m_timer_i,
                      // read / check port
                      input  logic [31:0] rd_instr_i,
                      output logic [63:0] rd_data_o,
                      output logic        rd_illegal_o,
                      // write port
                      input  logic        wr_en_i,
                      /* verilator lint_off UNUSEDSIGNAL */ // only csr address, funct3[1:0] and rs1 field are needed
                      input  logic [31:0] wr_instr_i,
                      /* verilator lint_on UNUSEDSIGNAL */
                      input  logic [63:0] wr_data_i,
                      // trap / return port
                      input  logic        exc_i,
                      input  logic [3:0]  exc_cause_i,
                      input  logic [63:0] exc_tval_i,
                      input  logic        irq_take_i,
                      /* verilator lint_off UNUSEDSIGNAL */ // mepc[1:0] = 0
                      input  logic [63:0] trap_pc_i,
                      /* verilator lint_on UNUSEDSIGNAL */
                      input  logic        mret_i,
                      input  logic        instret_i,
                      output logic        irq_pending_o,
                      output logic        wfi_wake_o,
                      output logic [63:0] trap_vec_o,
                      output logic [63:0] mepc_o
                    );

  localparam logic [6:0]  OPC_SYSTEM_C = 7'b1110011;
  localparam logic [31:0] ECALL_C      = 32'h0000_0073;
  localparam logic [31:0] EBREAK_C     = 32'h0010_0073;
  localparam logic [31:0] MRET_C       = 32'h3020_0073;
  localparam logic [31:0] WFI_C        = 32'h1050_0073;
  localparam logic [63:0] MISA_C       = 64'h8000_0000_0000_0100; // MXL = 2 (64 bit), I
  localparam logic [63:0] MIX_MASK_C   = 64'h0000_0000_0000_0888; // MEI, MTI, MSI
  localparam logic [63:0] MPP_M_C      = 64'h0000_0000_0000_1800;

  logic [2:0]  sync1_r;       // [0] ext, [1] soft, [2] timer
  logic [2:0]  sync2_r;

  logic        mstatus_mie_r;
  logic        mstatus_mpie_r;
  logic [63:0] mie_r;
  logic [63:0] mtvec_r;
  logic [63:0] mscratch_r;
  logic [63:0] mepc_r;
  logic        mcause_int_r;
  logic [3:0]  mcause_code_r;
  logic [63:0] mtval_r;
  logic [63:0] mcycle_r;
  logic [63:0] minstret_r;

  logic [63:0] mstatus_s;
  logic [63:0] mcause_s;
  logic [63:0] mip_s;
  logic [63:0] irq_act_s;     // pending and enabled in mie
  logic [3:0]  irq_code_s;
  logic        trap_s;

  logic        rd_is_csr_s;
  logic        rd_wintent_s;
  logic        rd_known_s;

  logic [11:0] wr_addr_s;
  logic        wr_s;          // write port really writes (write intent)
  logic [63:0] wr_old_s;
  logic [63:0] wr_new_s;

  assign mstatus_s = MPP_M_C | {56'b0, mstatus_mpie_r, 3'b0, mstatus_mie_r, 3'b0};
  assign mcause_s  = {mcause_int_r, 59'b0, mcause_code_r};
  assign mip_s     = {52'b0, sync2_r[0], 3'b0, sync2_r[2], 3'b0, sync2_r[1], 3'b0};
  assign irq_act_s = mip_s & mie_r;

  assign wfi_wake_o    = |irq_act_s;
  assign irq_pending_o = mstatus_mie_r & wfi_wake_o;
  assign mepc_o        = mepc_r;
  assign trap_s        = exc_i | irq_take_i;

  // csrrs/csrrc[i] with rs1 field = 0 only read; csrrw[i] always writes.
  assign rd_is_csr_s  = (rd_instr_i[6:0] == OPC_SYSTEM_C) && (rd_instr_i[13:12] != 2'b00);
  assign rd_wintent_s = (rd_instr_i[13:12] == 2'b01) || (rd_instr_i[19:15] != 5'd0);

  assign wr_addr_s = wr_instr_i[31:20];
  assign wr_s      = wr_en_i && ((wr_instr_i[13:12] == 2'b01) || (wr_instr_i[19:15] != 5'd0));

  // Priority MEI > MSI > MTI (privileged spec, section "Machine Interrupt Registers")
  always_comb
  begin
    if (irq_act_s[11])
      irq_code_s = 4'd11;
    else if (irq_act_s[3])
      irq_code_s = 4'd3;
    else
      irq_code_s = 4'd7;
  end

  always_comb
  begin
    trap_vec_o = {mtvec_r[63:2], 2'b00};
    if (irq_take_i && mtvec_r[0])
      trap_vec_o = {mtvec_r[63:2], 2'b00} + {58'b0, irq_code_s, 2'b00};
  end

  // Read port: old value and legality of the SYSTEM instruction
  always_comb
  begin
    rd_known_s = 1'b1;
    case (rd_instr_i[31:20])
      12'h300: rd_data_o = mstatus_s;
      12'h301: rd_data_o = MISA_C;
      12'h304: rd_data_o = mie_r;
      12'h305: rd_data_o = mtvec_r;
      12'h340: rd_data_o = mscratch_r;
      12'h341: rd_data_o = mepc_r;
      12'h342: rd_data_o = mcause_s;
      12'h343: rd_data_o = mtval_r;
      12'h344: rd_data_o = mip_s;
      12'hB00: rd_data_o = mcycle_r;
      12'hB02: rd_data_o = minstret_r;
      12'hC00: rd_data_o = mcycle_r;
      12'hC02: rd_data_o = minstret_r;
      12'hF11: rd_data_o = 64'd0;
      12'hF12: rd_data_o = 64'd0;
      12'hF13: rd_data_o = 64'd0;
      12'hF14: rd_data_o = HART_ID;
      12'hF15: rd_data_o = 64'd0;
      default:
      begin
        rd_data_o  = 64'd0;
        rd_known_s = 1'b0;
      end
    endcase
  end

  always_comb
  begin
    rd_illegal_o = 1'b0;
    if (rd_instr_i[6:0] == OPC_SYSTEM_C)
    begin
      if (rd_instr_i[14:12] == 3'b000)
        rd_illegal_o = (rd_instr_i != ECALL_C) && (rd_instr_i != EBREAK_C) &&
                       (rd_instr_i != MRET_C)  && (rd_instr_i != WFI_C);
      else if (rd_instr_i[14:12] == 3'b100)
        rd_illegal_o = 1'b1;
      else if (rd_is_csr_s)
        rd_illegal_o = !rd_known_s || ((rd_instr_i[31:30] == 2'b11) && rd_wintent_s);
    end
  end

  // Write port: read-modify-write on the addressed CSR
  always_comb
  begin
    case (wr_addr_s)
      12'h300: wr_old_s = mstatus_s;
      12'h304: wr_old_s = mie_r;
      12'h305: wr_old_s = mtvec_r;
      12'h340: wr_old_s = mscratch_r;
      12'h341: wr_old_s = mepc_r;
      12'h342: wr_old_s = mcause_s;
      12'h343: wr_old_s = mtval_r;
      12'hB00: wr_old_s = mcycle_r;
      12'hB02: wr_old_s = minstret_r;
      default: wr_old_s = 64'd0;
    endcase
  end

  always_comb
  begin
    case (wr_instr_i[13:12])
      2'b01:   wr_new_s = wr_data_i;
      2'b10:   wr_new_s = wr_old_s | wr_data_i;
      2'b11:   wr_new_s = wr_old_s & ~wr_data_i;
      default: wr_new_s = wr_old_s;
    endcase
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
    begin
      sync1_r <= 3'b000;
      sync2_r <= 3'b000;
    end
    else
    begin
      sync1_r <= {irq_m_timer_i, irq_m_soft_i, irq_m_ext_i};
      sync2_r <= sync1_r;
    end
  end

  // mstatus: interrupts are off after reset (privileged spec, "Reset")
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
    begin
      mstatus_mie_r  <= 1'b0;
      mstatus_mpie_r <= 1'b0;
    end
    else if (trap_s)
    begin
      mstatus_mpie_r <= mstatus_mie_r;
      mstatus_mie_r  <= 1'b0;
    end
    else if (mret_i)
    begin
      mstatus_mie_r  <= mstatus_mpie_r;
      mstatus_mpie_r <= 1'b1;
    end
    else if (wr_s && (wr_addr_s == 12'h300))
    begin
      mstatus_mie_r  <= wr_new_s[3];
      mstatus_mpie_r <= wr_new_s[7];
    end
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mie_r <= 64'd0;
    else if (wr_s && (wr_addr_s == 12'h304))
      mie_r <= wr_new_s & MIX_MASK_C;
  end

  // MODE[1] is hardwired to 0: values 2 and 3 are reserved
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mtvec_r <= MTVEC_RST;
    else if (wr_s && (wr_addr_s == 12'h305))
      mtvec_r <= {wr_new_s[63:2], 1'b0, wr_new_s[0]};
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mscratch_r <= 64'd0;
    else if (wr_s && (wr_addr_s == 12'h340))
      mscratch_r <= wr_new_s;
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mepc_r <= 64'd0;
    else if (trap_s)
      mepc_r <= {trap_pc_i[63:2], 2'b00};
    else if (wr_s && (wr_addr_s == 12'h341))
      mepc_r <= {wr_new_s[63:2], 2'b00};
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
    begin
      mcause_int_r  <= 1'b0;
      mcause_code_r <= 4'd0;
    end
    else if (irq_take_i)
    begin
      mcause_int_r  <= 1'b1;
      mcause_code_r <= irq_code_s;
    end
    else if (exc_i)
    begin
      mcause_int_r  <= 1'b0;
      mcause_code_r <= exc_cause_i;
    end
    else if (wr_s && (wr_addr_s == 12'h342))
    begin
      mcause_int_r  <= wr_new_s[63];
      mcause_code_r <= wr_new_s[3:0];
    end
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mtval_r <= 64'd0;
    else if (irq_take_i)
      mtval_r <= 64'd0;
    else if (exc_i)
      mtval_r <= exc_tval_i;
    else if (wr_s && (wr_addr_s == 12'h343))
      mtval_r <= wr_new_s;
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mcycle_r <= 64'd0;
    else if (wr_s && (wr_addr_s == 12'hB00))
      mcycle_r <= wr_new_s;
    else
      mcycle_r <= mcycle_r + 64'd1;
  end

  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      minstret_r <= 64'd0;
    else if (wr_s && (wr_addr_s == 12'hB02))
      minstret_r <= wr_new_s;
    else if (instret_i)
      minstret_r <= minstret_r + 64'd1;
  end

endmodule : cc_trap_csr
