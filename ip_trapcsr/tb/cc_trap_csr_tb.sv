// =============================================================================
// cc_trap_csr_tb.sv
// =============================================================================
// Self-checking testbench for cc_trap_csr (style of ip_icu/tb/cc_icu_tb.sv).
//
//   T1  Reset values (mstatus.MIE = 0, mie = 0, mtvec, misa, mhartid)
//   T2  Legality of SYSTEM instructions (unknown CSR, write to read-only CSR,
//       reserved funct3, funct3 = 000 encodings)
//   T3  WARL masks: mstatus, mie, mtvec, mepc, mcause, mip
//   T4  csrrs/csrrc semantics; rs1 = x0 does not write (minstret keeps counting)
//   T5  Interrupts: synchronizer delay, priority MEI > MSI > MTI, direct and
//       vectored mtvec, trap entry and MRET
//   T6  WFI wake-up is independent of mstatus.MIE
//   T7  Exception entry: mcause/mtval/mepc, vectored mtvec ignored
//   T8  Counters mcycle / minstret
// =============================================================================
`timescale 1ns/1ps

module cc_trap_csr_tb;

  localparam int          CLK_PERIOD = 10;
  localparam logic [63:0] HART_ID_C  = 64'd5;
  localparam logic [63:0] MTVEC_C    = 64'h0000_0000_0000_7F00;

  localparam logic [2:0]  CSRRW_C  = 3'b001;
  localparam logic [2:0]  CSRRS_C  = 3'b010;
  localparam logic [2:0]  CSRRC_C  = 3'b011;
  localparam logic [2:0]  CSRRWI_C = 3'b101;

  logic        clk_i, rst_i;
  logic        irq_m_ext_i, irq_m_soft_i, irq_m_timer_i;
  logic [31:0] rd_instr_i;
  logic [63:0] rd_data_o;
  logic        rd_illegal_o;
  logic        wr_en_i;
  logic [31:0] wr_instr_i;
  logic [63:0] wr_data_i;
  logic        exc_i;
  logic [3:0]  exc_cause_i;
  logic [63:0] exc_tval_i;
  logic        irq_take_i;
  logic [63:0] trap_pc_i;
  logic        mret_i;
  logic        instret_i;
  logic        irq_pending_o;
  logic        wfi_wake_o;
  logic [63:0] trap_vec_o;
  logic [63:0] mepc_o;

  logic [63:0] tmp_s;
  logic [63:0] tmp2_s;

  int pass_cnt = 0, fail_cnt = 0;

  initial clk_i = 1'b0;
  always  #(CLK_PERIOD/2) clk_i = ~clk_i;

  cc_trap_csr #(.HART_ID(HART_ID_C), .MTVEC_RST(MTVEC_C)) dut (
    .clk_i(clk_i), .rst_i(rst_i),
    .irq_m_ext_i(irq_m_ext_i), .irq_m_soft_i(irq_m_soft_i), .irq_m_timer_i(irq_m_timer_i),
    .rd_instr_i(rd_instr_i), .rd_data_o(rd_data_o), .rd_illegal_o(rd_illegal_o),
    .wr_en_i(wr_en_i), .wr_instr_i(wr_instr_i), .wr_data_i(wr_data_i),
    .exc_i(exc_i), .exc_cause_i(exc_cause_i), .exc_tval_i(exc_tval_i),
    .irq_take_i(irq_take_i), .trap_pc_i(trap_pc_i), .mret_i(mret_i), .instret_i(instret_i),
    .irq_pending_o(irq_pending_o), .wfi_wake_o(wfi_wake_o),
    .trap_vec_o(trap_vec_o), .mepc_o(mepc_o)
  );

  task automatic chk64(input string lbl, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-50s  got=%016h  exp=%016h", $realtime, lbl, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %s", $realtime, lbl);
      pass_cnt++;
    end
  endtask

  task automatic chk1(input string lbl, input logic got, input logic exp);
    chk64(lbl, 64'(got), 64'(exp));
  endtask

  function automatic logic [31:0] csr_instr(input logic [2:0] f3, input logic [11:0] csr, input logic [4:0] rs1);
    return {csr, rs1, f3, 5'd1, 7'b1110011};
  endfunction

  task automatic csr_read(input logic [11:0] csr, output logic [63:0] val);
    rd_instr_i = csr_instr(CSRRS_C, csr, 5'd0);
    #1;
    val = rd_data_o;
  endtask

  task automatic chk_csr(input string lbl, input logic [11:0] csr, input logic [63:0] exp);
    logic [63:0] val;
    csr_read(csr, val);
    chk64(lbl, val, exp);
  endtask

  task automatic csr_write(input logic [2:0] f3, input logic [11:0] csr, input logic [4:0] rs1, input logic [63:0] data);
    @(negedge clk_i);
    wr_en_i    = 1'b1;
    wr_instr_i = csr_instr(f3, csr, rs1);
    wr_data_i  = data;
    @(negedge clk_i);
    wr_en_i    = 1'b0;
  endtask

  task automatic check_legal(input string lbl, input logic [31:0] instr, input logic exp_illegal);
    rd_instr_i = instr;
    #1;
    chk1(lbl, rd_illegal_o, exp_illegal);
  endtask

  task automatic pulse_irq_take(input logic [63:0] pc);
    @(negedge clk_i);
    irq_take_i = 1'b1;
    trap_pc_i  = pc;
    @(negedge clk_i);
    irq_take_i = 1'b0;
  endtask

  task automatic pulse_mret();
    @(negedge clk_i);
    mret_i = 1'b1;
    @(negedge clk_i);
    mret_i = 1'b0;
  endtask

  initial begin
    rst_i = 1'b1;
    irq_m_ext_i = 1'b0; irq_m_soft_i = 1'b0; irq_m_timer_i = 1'b0;
    rd_instr_i = 32'h0000_0013;
    wr_en_i = 1'b0; wr_instr_i = 32'h0000_0013; wr_data_i = '0;
    exc_i = 1'b0; exc_cause_i = '0; exc_tval_i = '0;
    irq_take_i = 1'b0; trap_pc_i = '0; mret_i = 1'b0; instret_i = 1'b0;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i) rst_i = 1'b0;

    // ---------------------------------------------------------------- T1
    $display("--- T1 reset values");
    chk_csr("T1 mstatus = 0x1800 (MPP=11, MIE=0)", 12'h300, 64'h1800);
    chk_csr("T1 mie = 0",                          12'h304, 64'h0);
    chk_csr("T1 mtvec = MTVEC_RST",                12'h305, MTVEC_C);
    chk_csr("T1 misa = RV64I",                     12'h301, 64'h8000_0000_0000_0100);
    chk_csr("T1 mhartid = HART_ID",                12'hF14, HART_ID_C);
    chk_csr("T1 mvendorid = 0",                    12'hF11, 64'h0);
    chk1 ("T1 no interrupt pending",             irq_pending_o, 1'b0);

    // ---------------------------------------------------------------- T2
    $display("--- T2 legality");
    check_legal("T2 csrrs mhartid, x0 (read) legal",   csr_instr(CSRRS_C,  12'hF14, 5'd0), 1'b0);
    check_legal("T2 csrrw mhartid (write) illegal",    csr_instr(CSRRW_C,  12'hF14, 5'd0), 1'b1);
    check_legal("T2 csrrs mhartid, x1 (write) illegal",csr_instr(CSRRS_C,  12'hF14, 5'd1), 1'b1);
    check_legal("T2 csrrs cycle, x0 legal",            csr_instr(CSRRS_C,  12'hC00, 5'd0), 1'b0);
    check_legal("T2 csrrwi cycle illegal",             csr_instr(CSRRWI_C, 12'hC00, 5'd0), 1'b1);
    check_legal("T2 unknown CSR 0x7C0 illegal",        csr_instr(CSRRS_C,  12'h7C0, 5'd0), 1'b1);
    check_legal("T2 time (0xC01, not impl.) illegal",  csr_instr(CSRRS_C,  12'hC01, 5'd0), 1'b1);
    check_legal("T2 mscratch rw legal",                csr_instr(CSRRW_C,  12'h340, 5'd3), 1'b0);
    check_legal("T2 funct3 = 100 illegal",             csr_instr(3'b100,   12'h340, 5'd0), 1'b1);
    check_legal("T2 ECALL legal",                      32'h0000_0073, 1'b0);
    check_legal("T2 EBREAK legal",                     32'h0010_0073, 1'b0);
    check_legal("T2 MRET legal",                       32'h3020_0073, 1'b0);
    check_legal("T2 WFI legal",                        32'h1050_0073, 1'b0);
    check_legal("T2 SRET (no S-mode) illegal",         32'h1020_0073, 1'b1);
    check_legal("T2 non-SYSTEM opcode not flagged",    32'h0000_0013, 1'b0);

    // ---------------------------------------------------------------- T3
    $display("--- T3 WARL");
    csr_write(CSRRW_C, 12'h300, 5'd1, '1);
    chk_csr("T3 mstatus <- ~0 reads 0x1888",       12'h300, 64'h1888);
    csr_write(CSRRW_C, 12'h300, 5'd1, 64'h0);
    chk_csr("T3 mstatus <- 0 keeps MPP = 11",      12'h300, 64'h1800);
    csr_write(CSRRW_C, 12'h304, 5'd1, '1);
    chk_csr("T3 mie <- ~0 reads 0x888",            12'h304, 64'h888);
    csr_write(CSRRW_C, 12'h305, 5'd1, 64'h0000_0000_0000_7E03);
    chk_csr("T3 mtvec <- 0x7E03 reads 0x7E01",     12'h305, 64'h7E01);
    csr_write(CSRRW_C, 12'h341, 5'd1, 64'h0000_0000_0000_1237);
    chk_csr("T3 mepc <- 0x1237 reads 0x1234",      12'h341, 64'h1234);
    csr_write(CSRRW_C, 12'h342, 5'd1, '1);
    chk_csr("T3 mcause <- ~0 reads 0x8..0F",       12'h342, 64'h8000_0000_0000_000F);
    csr_write(CSRRW_C, 12'h344, 5'd1, '1);
    chk_csr("T3 mip <- ~0 stays 0 (read-only)",    12'h344, 64'h0);
    csr_write(CSRRW_C, 12'h340, 5'd1, 64'hDEAD_BEEF_0123_4567);
    chk_csr("T3 mscratch full 64 bit",             12'h340, 64'hDEAD_BEEF_0123_4567);

    // ---------------------------------------------------------------- T4
    $display("--- T4 csrrs/csrrc");
    csr_write(CSRRW_C, 12'h340, 5'd1, 64'h00F0);
    csr_write(CSRRS_C, 12'h340, 5'd1, 64'h000F);
    chk_csr("T4 csrrs sets bits",                  12'h340, 64'h00FF);
    csr_write(CSRRC_C, 12'h340, 5'd1, 64'h0011);
    chk_csr("T4 csrrc clears bits",                12'h340, 64'h00EE);
    csr_write(CSRRW_C, 12'hB02, 5'd1, 64'd100);
    @(negedge clk_i) instret_i = 1'b1;
    // csrrs minstret, x0 in the same cycle as a retire must not stop counting
    wr_en_i = 1'b1; wr_instr_i = csr_instr(CSRRS_C, 12'hB02, 5'd0); wr_data_i = 64'd0;
    @(negedge clk_i) instret_i = 1'b0; wr_en_i = 1'b0;
    chk_csr("T4 rs1 = x0 does not write minstret", 12'hB02, 64'd101);

    // ---------------------------------------------------------------- T5
    $display("--- T5 interrupts");
    csr_write(CSRRW_C, 12'h305, 5'd1, MTVEC_C);            // direct
    csr_write(CSRRW_C, 12'h304, 5'd1, 64'h888);
    csr_write(CSRRW_C, 12'h300, 5'd1, 64'h8);              // MIE = 1
    @(negedge clk_i) irq_m_timer_i = 1'b1;
    @(negedge clk_i);
    chk1 ("T5 MTIP not yet visible after 1 cycle", irq_pending_o, 1'b0);
    @(negedge clk_i);
    chk1 ("T5 MTIP pending after 2 cycles",       irq_pending_o, 1'b1);
    chk_csr("T5 mip = MTIP",                        12'h344, 64'h080);
    irq_take_i = 1'b1; #1;
    chk64("T5 direct mode: trap_vec = base",      trap_vec_o, MTVEC_C);
    irq_take_i = 1'b0;
    csr_write(CSRRW_C, 12'h305, 5'd1, MTVEC_C | 64'd1);    // vectored
    irq_take_i = 1'b1; #1;
    chk64("T5 vectored MTI: base + 4*7",          trap_vec_o, MTVEC_C + 64'd28);
    irq_take_i = 1'b0;
    @(negedge clk_i) irq_m_soft_i = 1'b1;
    repeat (2) @(negedge clk_i);
    irq_take_i = 1'b1; #1;
    chk64("T5 MSI beats MTI: base + 4*3",         trap_vec_o, MTVEC_C + 64'd12);
    irq_take_i = 1'b0;
    @(negedge clk_i) irq_m_ext_i = 1'b1;
    repeat (2) @(negedge clk_i);
    irq_take_i = 1'b1; #1;
    chk64("T5 MEI beats MSI/MTI: base + 4*11",    trap_vec_o, MTVEC_C + 64'd44);
    irq_take_i = 1'b0;
    pulse_irq_take(64'h0000_0000_0000_0123);
    chk_csr("T5 mcause = interrupt 11",             12'h342, 64'h8000_0000_0000_000B);
    chk64("T5 mepc = trap_pc, bits 1:0 cleared",  mepc_o, 64'h120);
    chk_csr("T5 mtval = 0 for interrupts",          12'h343, 64'h0);
    chk_csr("T5 mstatus: MIE = 0, MPIE = 1",        12'h300, 64'h1880);
    chk1 ("T5 MIE = 0 masks irq_pending_o",       irq_pending_o, 1'b0);
    pulse_mret();
    chk_csr("T5 MRET: MIE = 1, MPIE = 1",           12'h300, 64'h1888);
    chk1 ("T5 still pending after MRET (level)",  irq_pending_o, 1'b1);
    @(negedge clk_i) begin irq_m_ext_i = 1'b0; irq_m_soft_i = 1'b0; irq_m_timer_i = 1'b0; end
    repeat (2) @(negedge clk_i);
    chk1 ("T5 levels removed -> nothing pending", irq_pending_o, 1'b0);

    // ---------------------------------------------------------------- T6
    $display("--- T6 WFI wake-up");
    csr_write(CSRRW_C, 12'h300, 5'd1, 64'h0);              // MIE = 0
    @(negedge clk_i) irq_m_timer_i = 1'b1;
    repeat (2) @(negedge clk_i);
    chk1 ("T6 wfi_wake with MIE = 0",             wfi_wake_o, 1'b1);
    chk1 ("T6 but no irq_pending",                irq_pending_o, 1'b0);
    csr_write(CSRRC_C, 12'h304, 5'd1, 64'h080);            // MTIE = 0
    chk1 ("T6 masked in mie -> no wake",          wfi_wake_o, 1'b0);
    @(negedge clk_i) irq_m_timer_i = 1'b0;

    // ---------------------------------------------------------------- T7
    $display("--- T7 exception");
    csr_write(CSRRW_C, 12'h300, 5'd1, 64'h8);
    exc_i = 1'b1; #1;
    chk64("T7 vectored mtvec: exception -> base", trap_vec_o, MTVEC_C);
    exc_i = 1'b0;
    exc_cause_i = 4'd6; exc_tval_i = 64'h0000_0000_0000_0101; trap_pc_i = 64'h0000_0000_0000_0040;
    @(negedge clk_i) exc_i = 1'b1;
    @(negedge clk_i) exc_i = 1'b0;
    chk_csr("T7 mcause = 6 (store misaligned)",     12'h342, 64'd6);
    chk_csr("T7 mtval = faulting address",          12'h343, 64'h101);
    chk_csr("T7 mepc = faulting PC",                12'h341, 64'h40);
    chk_csr("T7 mstatus: MIE = 0, MPIE = 1",        12'h300, 64'h1880);

    // ---------------------------------------------------------------- T8
    $display("--- T8 counters");
    csr_read(12'hB00, tmp_s);
    repeat (10) @(negedge clk_i);
    csr_read(12'hB00, tmp2_s);
    chk64("T8 mcycle advances 10 per 10 cycles",  tmp2_s - tmp_s, 64'd10);
    csr_read(12'hC00, tmp_s);
    chk64("T8 cycle mirrors mcycle",              tmp_s, tmp2_s);
    csr_write(CSRRW_C, 12'hB00, 5'd1, 64'd0);
    chk_csr("T8 mcycle written to 0",             12'hB00, 64'd0);
    @(negedge clk_i);
    chk_csr("T8 mcycle counts on after write",    12'hB00, 64'd1);
    csr_read(12'hB02, tmp_s);
    @(negedge clk_i) instret_i = 1'b1;
    repeat (3) @(negedge clk_i);
    instret_i = 1'b0;
    csr_read(12'hB02, tmp2_s);
    chk64("T8 minstret counts instret_i",         tmp2_s - tmp_s, 64'd3);
    csr_read(12'hC02, tmp_s);
    chk64("T8 instret mirrors minstret",          tmp_s, tmp2_s);

    $display("==================================================");
    $display("cc_trap_csr_tb: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("RESULT: ALL TESTS PASSED");
    else               $display("RESULT: TESTS FAILED");
    $display("==================================================");
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL: watchdog timeout");
    $finish;
  end

endmodule : cc_trap_csr_tb
