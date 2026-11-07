// =============================================================================
// tb_cpupipefwd_cachefault.sv
// =============================================================================
// White-box, cc_cpupipefwd-only testbench (no cache/AXI4/full-chip instantiated)
// for the I-cache / D-cache AXI4-error trap path (mcause=1 / mcause=5, mtval).
// asICache.sv/asDCache.sv's own ic_err/dc_err generation is already unit-tested
// (ip_icache/tb/tb_asICache.sv TC07, ip_dcache/tb/tb_asDCache.sv TC10/TC11);
// this testbench instead drives icpu_if/dcpu_if directly with a scripted
// response queue, so the CPU's own consumption of ic_err/dc_err -- stall
// release, fault-flag threading through the pipeline, mcause/mepc/mtval -- can
// be checked without going through the real cache FSMs or a real AXI4 bus.
//
//   T0  Baseline: no fault, PC advances normally, mcause stays 0
//   T1  I-cache fault on the very first fetch -> mcause=1, mepc=mtval=0
//   T2  D-cache fault on a `lw x5,0(x0)` load  -> mcause=5, mepc=0, mtval=0
// =============================================================================
`timescale 1ns/1ps
import as_pack::*;

module tb_cpupipefwd_cachefault;

  localparam int CLK_PERIOD = 10;

  logic clk_i, rst_i;
  initial clk_i = 0;
  always #(CLK_PERIOD/2) clk_i = ~clk_i;

  logic [irq_total_num_ext_c-1:0] irq_ext_i;
  assign irq_ext_i = '0;

  as_icache_if icpu_if_s (.clk_i(clk_i), .rst_i(rst_i));
  as_dcache_if dcpu_if_s (.clk_i(clk_i), .rst_i(rst_i));

  cc_cpupipefwd dut (
    .clk_i(clk_i), .rst_i(rst_i), .tck_i(1'b0),
    .ir_o(), .dr_cap_i(1'b0),
    .sc01_tdo_o(), .sc01_tdi_i(1'b0),
    .sc01_shift_i(1'b0), .sc01_clock_i(1'b0),
    .icpu_if(icpu_if_s), .dcpu_if(dcpu_if_s),
    .irq_ext_i(irq_ext_i),
    .irq_m_soft_i(1'b0),
    .irq_m_timer_i(1'b0)
  );

  // ── Scorecard ───────────────────────────────────────────────────────────
  int pass_cnt = 0, fail_cnt = 0;

  task automatic chk64(input string lbl, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL [%7.1f ns] %-40s  got=%016h  exp=%016h", $realtime, lbl, got, exp);
      fail_cnt++;
    end else begin
      $display("PASS [%7.1f ns] %s", $realtime, lbl);
      pass_cnt++;
    end
  endtask

  // ── I-cache BFM ─────────────────────────────────────────────────────────
  // Response queue entries: bit[32]=1 -> fault (ic_err), else bits[31:0]=instr.
  // ic_stall/ic_flush_done are not read anywhere in cc_cpupipefwd.sv (grep-
  // confirmed) -- tied to 0 here since they carry no timing meaning to the DUT.
  logic [32:0] ic_resp_q[$];
  logic        ic_rvalid_r, ic_err_r;
  logic [31:0] ic_rdata_r;

  assign icpu_if_s.ic_stall      = 1'b0;
  assign icpu_if_s.ic_flush_done = 1'b0;
  assign icpu_if_s.ic_rvalid     = ic_rvalid_r;
  assign icpu_if_s.ic_rdata      = ic_rdata_r;
  assign icpu_if_s.ic_err        = ic_err_r;

  initial begin
    ic_rvalid_r = 1'b0; ic_err_r = 1'b0; ic_rdata_r = '0;
    forever begin
      @(posedge clk_i);
      ic_rvalid_r = 1'b0;
      ic_err_r    = 1'b0;
      if (icpu_if_s.ic_req) begin
        repeat (3) @(posedge clk_i);   // arbitrary fixed fill latency
        if (ic_resp_q.size() > 0) begin
          automatic logic [32:0] resp = ic_resp_q.pop_front();
          if (resp[32]) ic_err_r    = 1'b1;
          else begin    ic_rdata_r  = resp[31:0]; ic_rvalid_r = 1'b1; end
        end else begin
          ic_rdata_r = 32'h00000013; ic_rvalid_r = 1'b1;  // default: NOP
        end
      end
    end
  end

  // ── D-cache BFM ─────────────────────────────────────────────────────────
  // Response queue entries: bit[64]=1 -> fault (dc_err), else bits[63:0]=data.
  logic [64:0] dc_resp_q[$];
  logic        dc_rvalid_r, dc_err_r;
  logic [63:0] dc_rdata_r;

  assign dcpu_if_s.dc_stall      = 1'b0;
  assign dcpu_if_s.dc_flush_done = 1'b0;
  assign dcpu_if_s.dc_rvalid     = dc_rvalid_r;
  assign dcpu_if_s.dc_rdata      = dc_rdata_r;
  assign dcpu_if_s.dc_err        = dc_err_r;

  initial begin
    dc_rvalid_r = 1'b0; dc_err_r = 1'b0; dc_rdata_r = '0;
    forever begin
      @(posedge clk_i);
      dc_rvalid_r = 1'b0;
      dc_err_r    = 1'b0;
      if (dcpu_if_s.dc_req) begin
        repeat (3) @(posedge clk_i);
        if (dc_resp_q.size() > 0) begin
          automatic logic [64:0] resp = dc_resp_q.pop_front();
          if (resp[64]) dc_err_r    = 1'b1;
          else begin    dc_rdata_r  = resp[63:0]; dc_rvalid_r = 1'b1; end
        end else begin
          dc_rdata_r = 64'h0; dc_rvalid_r = 1'b1;  // default: OK, data=0
        end
      end
    end
  end

  // ── Reset ───────────────────────────────────────────────────────────────
  task automatic do_reset();
    rst_i = 1'b1;
    ic_resp_q.delete();
    dc_resp_q.delete();
    repeat (4) @(posedge clk_i);
    @(negedge clk_i); rst_i = 1'b0;
    @(posedge clk_i);
  endtask

  // lw x5, 0(x0)  (opcode=LOAD, funct3=010, rd=5, rs1=0, imm=0)
  localparam logic [31:0] INSTR_LW_X5_0_X0 = 32'h00002283;

  initial begin
    // =========================================================================
    // T0: baseline, no fault
    // =========================================================================
    do_reset();
    ic_resp_q.push_back(33'h0_00000013); // NOP
    ic_resp_q.push_back(33'h0_00000013); // NOP
    ic_resp_q.push_back(33'h0_00000013); // NOP
    repeat (40) @(posedge clk_i);
    chk64("T0 baseline: mcause stays 0 (no spurious trap)", 64'(dut.trap_csr.mcause_code_r), 64'd0);
    chk64("T0 baseline: PC advanced past reset (0x0)", (dut.PC_r != 64'h0), 64'd1);

    // =========================================================================
    // T1: I-cache fault on the very first fetch
    // =========================================================================
    do_reset();
    ic_resp_q.push_back(33'h1_00000000); // fault on fetch of PC=0
    ic_resp_q.push_back(33'h0_00000013); // NOP (fetched from mtvec after the trap)
    ic_resp_q.push_back(33'h0_00000013);
    ic_resp_q.push_back(33'h0_00000013);
    fork
      begin: t1_watch
        forever begin
          @(posedge clk_i);
          if (dut.wb_trap_taken_s) begin
            #1;  // let this edge's NBA (PC_r/CSRs) settle before reading
            disable t1_watch;
          end
        end
      end
      begin: t1_timeout
        repeat (60) @(posedge clk_i);
      end
    join_any
    disable fork;
    chk64("T1 icfault: mcause == 1 (Instruction access fault)", 64'(dut.trap_csr.mcause_code_r), 64'd1);
    chk64("T1 icfault: mepc == 0 (faulting fetch address)",     dut.trap_csr.mepc_r,   64'd0);
    chk64("T1 icfault: mtval == 0 (faulting fetch address)",    dut.trap_csr.mtval_r,  64'd0);
    chk64("T1 icfault: PC redirected to mtvec (0x7F00)",        dut.PC_r,         64'h7F00);

    // =========================================================================
    // T2: D-cache fault on a load (lw x5, 0(x0))
    // =========================================================================
    do_reset();
    ic_resp_q.push_back({1'b0, INSTR_LW_X5_0_X0});
    ic_resp_q.push_back(33'h0_00000013); // NOP (fetched from mtvec after the trap)
    ic_resp_q.push_back(33'h0_00000013);
    ic_resp_q.push_back(33'h0_00000013);
    dc_resp_q.push_back(65'h1_0000000000000000); // fault on the LW's data access
    fork
      begin: t2_watch
        forever begin
          @(posedge clk_i);
          if (dut.wb_trap_taken_s) begin
            #1;  // let this edge's NBA (PC_r/CSRs) settle before reading
            disable t2_watch;
          end
        end
      end
      begin: t2_timeout
        repeat (60) @(posedge clk_i);
      end
    join_any
    disable fork;
    chk64("T2 dcfault: mcause == 5 (Load access fault)", 64'(dut.trap_csr.mcause_code_r), 64'd5);
    chk64("T2 dcfault: mepc == 0 (PC of the LW instruction)", dut.trap_csr.mepc_r, 64'd0);
    chk64("T2 dcfault: mtval == 0 (faulting load address, x0+0)", dut.trap_csr.mtval_r, 64'd0);
    chk64("T2 dcfault: PC redirected to mtvec (0x7F00)", dut.PC_r, 64'h7F00);

    // =========================================================================
    // Summary
    // =========================================================================
    repeat (5) @(posedge clk_i);
    $display("\n============================================================");
    $display("  SUMMARY:  %0d PASSED,  %0d FAILED", pass_cnt, fail_cnt);
    $display("============================================================");
    if (fail_cnt == 0) $display("  ALL TESTS PASSED");
    else                $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #200_000; $display("FAIL  WATCHDOG"); $finish; end

endmodule : tb_cpupipefwd_cachefault
