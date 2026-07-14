// =============================================================================
// cc_icu_tb.sv
// =============================================================================
// Self-checking testbench for cc_icu_top (mirrors ip_qspi/tb/asQspiTop_tb.sv
// style: chk64/chk1 scorecard tasks, wb_write/wb_read WB tasks, PASS/FAIL
// summary, watchdog).
//
//   T1  Reset defaults (ID/RIS/IMSC/MIS/PRIO/IRQID/CTRL)
//   T2  Edge-triggered pending: RIS sets on a 0->1 source edge, stays sticky
//   T3  MIS = RIS & IMSC (masking hides a pending source from MIS/IRQID)
//   T4  ICR clears RIS (write-1-to-clear)
//   T5  ISR force-sets RIS without a real source edge
//   T6  SET-over-CLEAR coincidence: a real edge landing in the same cycle as
//       an ICR write to the same bit must not lose the new occurrence
//   T7  Priority arbitration across multiple simultaneously pending sources
//   T8  Tie-break: equal priority -> lowest source index wins
//   T9  Masking removes a source from arbitration (lower-prio winner instead)
//   T10 CTRL.GIE gates icu_irq_o only, not IRQID/valid
//   T11 All-idle sanity: no sources pending -> valid=0, irq_o=0
// =============================================================================
`timescale 1ns/1ps
import as_pack::*;

module cc_icu_tb;

  localparam int CLK_PERIOD = 10;
  localparam int ADDR_W     = 8;   // matches ICU0_AW used at chip level
  localparam int DATA_W     = 64;
  localparam int NSRC       = icu_num_sources;

  // ── clock / reset ───────────────────────────────────────────────────────
  logic rst_i, clk_i;
  initial clk_i = 0;
  always  #(CLK_PERIOD/2) clk_i = ~clk_i;

  // ── Wishbone signals ────────────────────────────────────────────────────
  logic [ADDR_W-1:0] wbdAddr_i;
  logic [DATA_W-1:0] wbdDat_i;
  logic [DATA_W-1:0] wbdDat_o;
  logic              wbdWe_i, wbdStb_i, wbdAck_o, wbdCyc_i;
  logic [wbdSel-1:0] wbdSel_i;

  // ── sources / IRQ output ────────────────────────────────────────────────
  logic [NSRC-1:0] irq_src_i;
  logic            icu_irq_o;

  // ── DUT ─────────────────────────────────────────────────────────────────
  cc_icu_top #(.ICU_ADDR_WIDTH(ADDR_W), .ICU_DATA_WIDTH(DATA_W), .NUM_SOURCES(NSRC)) dut (
    .rst_i(rst_i), .clk_i(clk_i),
    .wbdAddr_i(wbdAddr_i), .wbdDat_i(wbdDat_i), .wbdDat_o(wbdDat_o),
    .wbdWe_i(wbdWe_i), .wbdSel_i(wbdSel_i), .wbdStb_i(wbdStb_i),
    .wbdAck_o(wbdAck_o), .wbdCyc_i(wbdCyc_i),
    .irq_src_i(irq_src_i), .icu_irq_o(icu_irq_o)
  );

  // ── Scorecard ───────────────────────────────────────────────────────────
  int pass_cnt = 0, fail_cnt = 0;

  task automatic chk64(input string lbl, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-46s  got=%016h  exp=%016h", $realtime, lbl, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %s", $realtime, lbl);
      pass_cnt++;
    end
  endtask

  task automatic chk1(input string lbl, input logic got, input logic exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-46s  got=%b exp=%b", $realtime, lbl, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %s", $realtime, lbl);
      pass_cnt++;
    end
  endtask

  // ── Wishbone tasks ──────────────────────────────────────────────────────
  task automatic wb_write(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
    @(negedge clk_i);
    wbdAddr_i=addr; wbdDat_i=data; wbdWe_i=1; wbdSel_i='1; wbdStb_i=1; wbdCyc_i=1;
    @(posedge clk_i); #1;
    @(negedge clk_i); wbdStb_i=0; wbdCyc_i=0; wbdWe_i=0;
  endtask

  task automatic wb_read(input logic [ADDR_W-1:0] addr, output logic [DATA_W-1:0] rdata);
    @(negedge clk_i);
    wbdAddr_i=addr; wbdWe_i=0; wbdSel_i='1; wbdStb_i=1; wbdCyc_i=1;
    @(posedge clk_i); #1; rdata=wbdDat_o;
    @(negedge clk_i); wbdStb_i=0; wbdCyc_i=0;
  endtask

  task automatic do_reset();
    rst_i=1;
    wbdAddr_i='0; wbdDat_i='0; wbdWe_i=0; wbdSel_i='0; wbdStb_i=0; wbdCyc_i=0;
    irq_src_i='0;
    repeat(4) @(posedge clk_i);
    @(negedge clk_i); rst_i=0;
    @(posedge clk_i);
  endtask

  // ── Register offsets: taken directly from as_pack.sv (same constants the
  //    RTL decodes against), so TB and RTL cannot silently drift apart.
  localparam logic [ADDR_W-1:0]
    A_ID   = ADDR_W'(icu_id_reg_addr_offs_c),
    A_RIS  = ADDR_W'(icu_ris_reg_addr_offs_c),
    A_IMSC = ADDR_W'(icu_imsc_reg_addr_offs_c),
    A_MIS  = ADDR_W'(icu_mis_reg_addr_offs_c),
    A_ICR  = ADDR_W'(icu_icr_reg_addr_offs_c),
    A_ISR  = ADDR_W'(icu_isr_reg_addr_offs_c),
    A_PRIO = ADDR_W'(icu_prio_reg_addr_offs_c),
    A_IRQID= ADDR_W'(icu_irqid_reg_addr_offs_c),
    A_CTRL = ADDR_W'(icu_ctrl_reg_addr_offs_c);

  logic [DATA_W-1:0] rd_g;

  initial begin
    do_reset();

    // =========================================================================
    // T1: Reset defaults
    // =========================================================================
    wb_read(A_ID,   rd_g); chk64("T1 ID reset value",    rd_g, icu_id_reg_rst_c);
    wb_read(A_RIS,  rd_g); chk64("T1 RIS reset = 0",      rd_g, 64'h0);
    wb_read(A_IMSC, rd_g); chk64("T1 IMSC reset = all-1", rd_g, icu_imsc_reg_rst_c);
    wb_read(A_MIS,  rd_g); chk64("T1 MIS reset = 0",      rd_g, 64'h0);
    wb_read(A_PRIO, rd_g); chk64("T1 PRIO reset value",   rd_g, icu_prio_reg_rst_c);
    wb_read(A_IRQID,rd_g); chk64("T1 IRQID reset: no IRQ",rd_g, 64'h0);
    wb_read(A_CTRL, rd_g); chk64("T1 CTRL reset: GIE=1",  rd_g, icu_ctrl_reg_rst_c);
    chk1("T1 icu_irq_o idle", icu_irq_o, 1'b0);

    // =========================================================================
    // T2: Edge-triggered pending (source 0 = GPIO0 slot)
    // =========================================================================
    irq_src_i[0] = 1'b1;
    repeat(4) @(posedge clk_i);
    wb_read(A_RIS, rd_g);
    chk1("T2 RIS[0] set after source edge", rd_g[0], 1'b1);
    // source stays high: no re-pulse, but RIS must stay sticky (not self-clear)
    repeat(4) @(posedge clk_i);
    wb_read(A_RIS, rd_g);
    chk1("T2 RIS[0] stays sticky while source held high", rd_g[0], 1'b1);
    irq_src_i[0] = 1'b0;
    repeat(2) @(posedge clk_i);

    // =========================================================================
    // T3: MIS = RIS & IMSC
    // =========================================================================
    wb_write(A_IMSC, {DATA_W{1'b0}}); // mask everything
    wb_read(A_MIS, rd_g);
    chk1("T3 MIS[0]=0 while masked (RIS still 1)", rd_g[0], 1'b0);
    wb_read(A_IRQID, rd_g);
    chk1("T3 IRQID invalid while masked", rd_g[3], 1'b0);
    wb_write(A_IMSC, {DATA_W{1'b1}}); // unmask all
    @(posedge clk_i); #1; // mis_reg_s registered readback needs 1 extra cycle
    wb_read(A_MIS, rd_g);
    chk1("T3 MIS[0]=1 once unmasked", rd_g[0], 1'b1);

    // =========================================================================
    // T4: ICR clears RIS
    // =========================================================================
    wb_write(A_ICR, 64'h1);
    wb_read(A_RIS, rd_g);
    chk1("T4 RIS[0] cleared by ICR", rd_g[0], 1'b0);

    // =========================================================================
    // T5: ISR force-sets RIS without a real edge
    // =========================================================================
    wb_write(A_ISR, 64'h1);
    wb_read(A_RIS, rd_g);
    chk1("T5 RIS[0] set by ISR (SW force)", rd_g[0], 1'b1);
    wb_write(A_ICR, 64'h1); // clean up for next tests
    wb_read(A_RIS, rd_g);
    chk1("T5 cleanup: RIS[0] cleared", rd_g[0], 1'b0);

    // =========================================================================
    // T6: SET-over-CLEAR coincidence
    // A real edge on source 1 (UART0 slot) is timed to land in the RIS
    // always_ff exactly the same cycle as a WB ICR write to the same bit.
    // With the shift-register edge detector, a rising edge presented before
    // clock edge E1 produces irq_pulse_o=1 for exactly the cycle between E1
    // and E2; the RIS flop samples that pulse at E2. So: raise the source
    // right before E1, then drive an ICR write whose single active WB cycle
    // (its one posedge) is E2.
    // =========================================================================
    @(negedge clk_i);
    irq_src_i[1] = 1'b1;                 // armed before E1
    @(posedge clk_i);                    // this is E1: shift[1][0]<=1 captured
    @(negedge clk_i);
    // Now inside the cycle between E1 and E2: irq_pulse_o[1] is high.
    // Drive an ICR write targeting bit 1 so its capture edge is E2.
    wbdAddr_i=A_ICR; wbdDat_i=64'h2; wbdWe_i=1; wbdSel_i='1; wbdStb_i=1; wbdCyc_i=1;
    @(posedge clk_i);                    // E2: RIS ff sees pulse=1 AND wr_icr&data[1]=1 simultaneously
    #1;
    @(negedge clk_i); wbdStb_i=0; wbdCyc_i=0; wbdWe_i=0;
    irq_src_i[1] = 1'b0;
    wb_read(A_RIS, rd_g);
    chk1("T6 SET wins over coincident CLEAR", rd_g[1], 1'b1);
    wb_write(A_ICR, 64'h2); // clean up (no coincidence this time)
    wb_read(A_RIS, rd_g);
    chk1("T6 cleanup: RIS[1] cleared", rd_g[1], 1'b0);

    // =========================================================================
    // T7 / T8: Priority arbitration + tie-break
    // Sources 0,1,2 forced pending via ISR; priorities: src0=5, src1=9, src2=5
    // -> src1 must win (highest). Then drop src1 -> src0 vs src2 tie (both 5)
    // -> lowest index (src0) must win.
    // =========================================================================
    wb_write(A_PRIO, {{(DATA_W-12){1'b0}}, 4'd5, 4'd9, 4'd5}); // src2=5,src1=9,src0=5
    wb_write(A_ISR, 64'h7); // force src0,1,2 pending
    @(posedge clk_i); #1;
    wb_read(A_IRQID, rd_g);
    chk1("T7 IRQID.valid=1 (3 sources pending)", rd_g[3], 1'b1);
    chk64("T7 IRQID.id = src1 (highest prio=9)", 64'(rd_g[2:0]), 64'd1);

    wb_write(A_ICR, 64'h2); // clear src1 -> now src0 vs src2 tie at prio 5
    @(posedge clk_i); #1;
    wb_read(A_IRQID, rd_g);
    chk64("T8 tie-break: IRQID.id = src0 (lowest index)", 64'(rd_g[2:0]), 64'd0);

    wb_write(A_ICR, 64'h5); // clean up src0, src2

    // =========================================================================
    // T9: Masking removes a source from arbitration
    // =========================================================================
    wb_write(A_PRIO, {{(DATA_W-8){1'b0}}, 4'd9, 4'd3}); // src0=3, src1=9
    wb_write(A_ISR, 64'h3); // force src0, src1 pending
    @(posedge clk_i); #1;
    wb_read(A_IRQID, rd_g);
    chk64("T9 before mask: IRQID.id = src1 (prio 9)", 64'(rd_g[2:0]), 64'd1);

    wb_write(A_IMSC, 64'hFD); // mask src1 (bit1=0), keep everything else enabled
    @(posedge clk_i); #1;
    wb_read(A_IRQID, rd_g);
    chk64("T9 after masking src1: IRQID.id = src0", 64'(rd_g[2:0]), 64'd0);
    chk1("T9 IRQID.valid still 1 (src0 unmasked)", rd_g[3], 1'b1);

    wb_write(A_IMSC, {DATA_W{1'b1}}); // restore
    wb_write(A_ICR, 64'h3);           // clean up

    // =========================================================================
    // T10: CTRL.GIE gates icu_irq_o only, not IRQID/valid
    // =========================================================================
    wb_write(A_ISR, 64'h1); // force src0 pending (prio already set to 3 from T9)
    @(posedge clk_i); #1;
    wb_read(A_IRQID, rd_g);
    chk1("T10 IRQID.valid=1 with GIE=1", rd_g[3], 1'b1);
    chk1("T10 icu_irq_o=1 with GIE=1", icu_irq_o, 1'b1);

    wb_write(A_CTRL, 64'h0); // GIE=0
    @(posedge clk_i); #1;
    chk1("T10 icu_irq_o=0 with GIE=0", icu_irq_o, 1'b0);
    wb_read(A_IRQID, rd_g);
    chk1("T10 IRQID.valid still 1 with GIE=0 (diagnostic reg unaffected)", rd_g[3], 1'b1);

    wb_write(A_CTRL, 64'h1); // restore GIE=1
    wb_write(A_ICR, 64'h1);  // clean up
    @(posedge clk_i); #1;

    // =========================================================================
    // T11: All-idle sanity
    // =========================================================================
    wb_read(A_RIS, rd_g);  chk64("T11 RIS all clear",  rd_g, 64'h0);
    wb_read(A_IRQID, rd_g); chk1("T11 IRQID.valid=0",   rd_g[3], 1'b0);
    chk1("T11 icu_irq_o=0", icu_irq_o, 1'b0);

    // =========================================================================
    // Summary
    // =========================================================================
    repeat(5) @(posedge clk_i);
    $display("\n============================================================");
    $display("  SUMMARY:  %0d PASSED,  %0d FAILED", pass_cnt, fail_cnt);
    $display("============================================================");
    if (fail_cnt==0) $display("  ALL TESTS PASSED");
    else             $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #1_000_000; $display("FAIL  WATCHDOG"); $finish; end

endmodule : cc_icu_tb
