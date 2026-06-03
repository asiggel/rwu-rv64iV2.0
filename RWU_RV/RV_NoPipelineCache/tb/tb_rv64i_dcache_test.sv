`timescale 1ns/1ps

import as_pack::*;

// Testbench for dcache_test.asm
//
// Verifies 6 ordered GPIO checkpoints (0x01..0x06, then 0x55).
// Additionally monitors D-Cache internals:
//   - fill events: which way was filled, PLRU state after
//   - hit events:  which way hit
//   - PLRU assertions at checkpoints 0x01, 0x03, 0x04
//   - valid-bits assertion at checkpoint 0x03
//
// D-Cache FSM encoding (from asDCache.sv):
//   0=IDLE  1=LOOKUP  5=MISS  6=FILL  7=FILL_RESP  (others: evict/flush)
module tb_rv64i ();
  parameter tclk_2_t = 20;
  parameter clk_2_t  = 5;
  parameter clk_80_t = 400;

  logic clk_s, clk_core_s, clk_div_s;
  logic rst_s;
  logic tck_s, trst_s, tms_s, tdi_s, tdo_s;
  tri [nr_gpios-1:0] gpio_s;
  logic              cs_s;
  int fd;
  int phase_s;

  localparam int FLASH_WORDS = 16384;
  logic [31:0] flash_mem_s [0:FLASH_WORDS-1];
  initial $readmemh("riscvtest.mem", flash_mem_s);

  logic       sck_s;
  logic       flash_cs_s;
  wire  [3:0] flash_data_s;
  logic [3:0] flash_drive_s = 4'b0;
  logic       flash_oe_s    = 1'b0;
  assign flash_data_s = flash_oe_s ? flash_drive_s : 4'bzzzz;

  as_top_mem DUT (
    .clk_i        (clk_s),
    .rst_i        (rst_s),
    .tck_i        (tck_s),
    .trst_i       (trst_s),
    .tms_i        (tms_s),
    .tdi_i        (tdi_s),
    .tdo_o        (tdo_s),
    .gpio_io      (gpio_s),
    .cs_o         (cs_s),
    .sck_o        (sck_s),
    .flash_cs_o   (flash_cs_s),
    .flash_data_io(flash_data_s),
    .clk_div_o    (clk_div_s)
  );

  initial begin rst_s  <= 1; #(10*2*clk_2_t); rst_s  <= 0; end
  initial begin phase_s = 0; fd = $fopen("./error.txt", "a"); end
  always  begin clk_s  <= 1; #clk_2_t; clk_s  <= 0; #clk_2_t; end
  always  begin clk_core_s <= 1; #clk_80_t; clk_core_s <= 0; #clk_80_t; end
  initial begin tck_s <= 0; tms_s <= 0; tdi_s <= 0; trst_s <= 0; end

  initial begin #2000000000; $display("WATCHDOG: 2 ms timeout"); $finish; end

  // ── D-Cache state monitor ─────────────────────────────────────────────────
  // Shorthand path into D-Cache (read-only — never drive)
  localparam logic [3:0] DC_IDLE      = 4'd0;
  localparam logic [3:0] DC_LOOKUP    = 4'd1;
  localparam logic [3:0] DC_MISS      = 4'd5;
  localparam logic [3:0] DC_FILL      = 4'd6;
  localparam logic [3:0] DC_FILL_RESP = 4'd7;

  logic [3:0] dc_prev_state_s;
  always_ff @(posedge clk_div_s)
    dc_prev_state_s <= DUT.memtop.dcache.dc_state_s;

  always @(posedge clk_div_s) begin
    // Log every fill completion (FILL_RESP_ST entry)
    if (DUT.memtop.dcache.dc_state_s == DC_FILL_RESP &&
        dc_prev_state_s              != DC_FILL_RESP) begin
      $display("[DC FILL ] set=%0d tag=0x%03x way=%0d  PLRU[set]=%03b  valid=%04b",
               int'(DUT.memtop.dcache.lk_idx_r),
               int'(DUT.memtop.dcache.lk_tag_r),
               int'(DUT.memtop.dcache.fill_way_r),
               DUT.memtop.dcache.plru_r[DUT.memtop.dcache.lk_idx_r],
               DUT.memtop.dcache.vd_valid_s);
    end
    // Log every cache hit (LOOKUP_ST with hit)
    if (DUT.memtop.dcache.dc_state_s == DC_LOOKUP &&
        DUT.memtop.dcache.hit_s) begin
      $display("[DC HIT  ] set=%0d tag=0x%03x way=%0d  PLRU[set]=%03b",
               int'(DUT.memtop.dcache.lk_idx_r),
               int'(DUT.memtop.dcache.lk_tag_r),
               int'(DUT.memtop.dcache.hit_way_s),
               DUT.memtop.dcache.plru_r[DUT.memtop.dcache.lk_idx_r]);
    end
    // Log every cache miss (LOOKUP_ST → MISS_ST transition)
    if (DUT.memtop.dcache.dc_state_s == DC_MISS &&
        dc_prev_state_s              != DC_MISS) begin
      $display("[DC MISS ] set=%0d tag=0x%03x  all_valid=%0b",
               int'(DUT.memtop.dcache.lk_idx_r),
               int'(DUT.memtop.dcache.lk_tag_r),
               &DUT.memtop.dcache.vd_valid_s);
    end
  end

  //------------------------------------------
  // QSPI NOR flash model (W25Q-style, Quad Output Fast Read 0x6B)
  //------------------------------------------
  task automatic flash_transaction();
    logic [23:0] faddr = '0;
    logic [63:0] fword = '0;
    int          widx  = 0;
    int          cnt   = 0;
    int          idx   = 0;
    flash_oe_s    = 1'b0;
    flash_drive_s = 4'b0;
    while (flash_cs_s) begin
      @(posedge sck_s); if (!flash_cs_s) return;
      cnt++;
      if (cnt >= 9 && cnt <= 14)
        faddr = {faddr[19:0], flash_data_s[3:0]};
      if (cnt >= 22 && idx < 16) begin
        @(negedge sck_s); if (!flash_cs_s) return;
        if (idx == 0) begin
          widx  = int'(faddr) >> 2;
          fword = {flash_mem_s[widx+1], flash_mem_s[widx]};
        end
        flash_oe_s    = 1'b1;
        flash_drive_s = fword[63:60];
        fword         = {fword[59:0], 4'b0};
        idx++;
        if (idx == 16) begin @(posedge sck_s); return; end
      end
    end
  endtask

  always @(negedge flash_cs_s) begin flash_oe_s = 1'b0; flash_drive_s = 4'b0; end
  always begin
    @(posedge flash_cs_s);
    flash_transaction();
    flash_oe_s    = 1'b0;
    flash_drive_s = 4'b0;
  end

  //------------------------------------------
  // Checkpoint monitor
  // Expects GPIO sequence: 1, 2, 3, 4, 5, 6, 0x55
  //
  // PLRU assertions (asDCache plru_upd, initial state = 3'b000):
  //   After phase1 (fill W0 + hits W0):  plru_r[0] = 3'b011
  //   After phase3 (fill W1, W2, W3):    plru_r[0] = 3'b000
  //   After phase4 (PLRU evict W0→tag12): plru_r[0] = 3'b011
  //------------------------------------------
  always @(posedge cs_s) begin
    begin
      #1; // allow gpio_io to settle (same NBA region as cs_o)
      $display("D-Cache test: GPIO = 0x%02h  (phase %0d)", gpio_s[7:0], phase_s);
      case (gpio_s[7:0])

        8'h01: begin
          if (phase_s !== 0) begin
            $display("FAIL: unexpected checkpoint 1 in phase %0d", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL phase seq @cp1", get_time());
            $fclose(fd); $stop;
          end
          // plru_r[0]: W0 filled then hit 2×  → 3'b011
          if (DUT.memtop.dcache.plru_r[0] !== 3'b011) begin
            $display("FAIL @cp1: plru_r[0]=%03b, expected 3'b011 (W0 MRU)",
                     DUT.memtop.dcache.plru_r[0]);
            $fdisplay(fd, "%s - dcache_test: FAIL PLRU @cp1", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 1 pass: cold miss + fill + intra-line hits  PLRU[0]=%03b",
                   DUT.memtop.dcache.plru_r[0]);
          phase_s = 1;
        end

        8'h02: begin
          if (phase_s !== 1) begin
            $display("FAIL: unexpected checkpoint 2 in phase %0d", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL phase seq @cp2", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 2 pass: sub-word sign/zero extension ok");
          phase_s = 2;
        end

        8'h03: begin
          if (phase_s !== 2) begin
            $display("FAIL: unexpected checkpoint 3 in phase %0d", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL phase seq @cp3", get_time());
            $fclose(fd); $stop;
          end
          // After filling W1, W2, W3 sequentially: plru_r[0] = 3'b000
          if (DUT.memtop.dcache.plru_r[0] !== 3'b000) begin
            $display("FAIL @cp3: plru_r[0]=%03b, expected 3'b000 (W3 most recent)",
                     DUT.memtop.dcache.plru_r[0]);
            $fdisplay(fd, "%s - dcache_test: FAIL PLRU @cp3", get_time());
            $fclose(fd); $stop;
          end
          // All 4 ways of set0 must now be valid
          if (DUT.memtop.dcache.vd_valid_s !== 4'b1111) begin
            $display("FAIL @cp3: vd_valid_s=%04b, expected 4'b1111",
                     DUT.memtop.dcache.vd_valid_s);
            $fdisplay(fd, "%s - dcache_test: FAIL valid bits @cp3", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 3 pass: all 4 ways filled  PLRU[0]=%03b  valid=%04b",
                   DUT.memtop.dcache.plru_r[0],
                   DUT.memtop.dcache.vd_valid_s);
          phase_s = 3;
        end

        8'h04: begin
          if (phase_s !== 3) begin
            $display("FAIL: unexpected checkpoint 4 in phase %0d", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL phase seq @cp4", get_time());
            $fclose(fd); $stop;
          end
          // W0 was the PLRU victim (plru_r[0]=3'b000 → p[0]=0 left-LRU, p[1]=0 → W0).
          // After refill of W0 with tag12: plru_r[0] = 3'b011
          if (DUT.memtop.dcache.plru_r[0] !== 3'b011) begin
            $display("FAIL @cp4: plru_r[0]=%03b, expected 3'b011 (W0 refilled)",
                     DUT.memtop.dcache.plru_r[0]);
            $fdisplay(fd, "%s - dcache_test: FAIL PLRU @cp4", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 4 pass: PLRU eviction W0 (tag8→tag12)  PLRU[0]=%03b",
                   DUT.memtop.dcache.plru_r[0]);
          phase_s = 4;
        end

        8'h05: begin
          if (phase_s !== 4) begin
            $display("FAIL: unexpected checkpoint 5 in phase %0d", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL phase seq @cp5", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 5 pass: evicted tag8 reloaded + set1 cold miss ok");
          phase_s = 5;
        end

        8'h06: begin
          if (phase_s !== 5) begin
            $display("FAIL: unexpected checkpoint 6 in phase %0d", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL phase seq @cp6", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 6 pass: warm-cache hits on set1/tag8, set0/tag9, set0/tag11 ok");
          phase_s = 6;
        end

        8'h55: begin
          if (phase_s !== 6) begin
            $display("FAIL: final 0x55 before all checkpoints (phase %0d)", phase_s);
            $fdisplay(fd, "%s - dcache_test: FAIL early 0x55", get_time());
            $fclose(fd); $stop;
          end
          $display("Simulation dcache_test PASSED");
          #100; #(1*2*clk_2_t);
          $fdisplay(fd, "%s - dcache_test: Test ok", get_time());
          $fclose(fd); $stop;
        end

        8'hFF: begin
          $display("FAIL: ASM branch-to-fail triggered in phase %0d", phase_s);
          $fdisplay(fd, "%s - dcache_test: Test fail (0xFF)", get_time());
          $fclose(fd); $stop;
        end

        default: begin
          $display("FAIL: unexpected GPIO value 0x%02h in phase %0d", gpio_s[7:0], phase_s);
          $fdisplay(fd, "%s - dcache_test: Test fail (unexpected GPIO)", get_time());
          $fclose(fd); $stop;
        end

      endcase
    end
  end

  function string get_time();
    int file_pointer;
    void'($system("date +%x > sys_time"));
    file_pointer = $fopen("sys_time","r");
    void'($fscanf(file_pointer,"%s",get_time));
    $fclose(file_pointer);
    void'($system("rm sys_time"));
  endfunction

endmodule : tb_rv64i
