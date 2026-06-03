`timescale 1ns/1ps

import as_pack::*;

// Testbench for memory_sections.asm
//
// Verifies 5 ordered GPIO checkpoints (0x01..0x05, then 0x55):
//   0x01  .data variables correctly initialised from Flash LMA
//   0x02  .bss array all-zero after startup zero-loop
//   0x03  .rodata constant table readable via D-Cache
//   0x04  stack push/pop round-trip (canary survives)
//   0x05  heap write/read-back correct
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
  // Expects GPIO sequence: 1, 2, 3, 4, 5, 0x55
  //------------------------------------------
  always @(posedge cs_s) begin
    begin
      #1;
      $display("Memory-sections test: GPIO = 0x%02h  (phase %0d)", gpio_s[7:0], phase_s);
      case (gpio_s[7:0])

        8'h01: begin
          if (phase_s !== 0) begin
            $display("FAIL: unexpected checkpoint 1 in phase %0d", phase_s);
            $fdisplay(fd, "%s - memory_sections: FAIL phase seq @cp1", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 1 pass: .data variables correctly initialised from Flash");
          phase_s = 1;
        end

        8'h02: begin
          if (phase_s !== 1) begin
            $display("FAIL: unexpected checkpoint 2 in phase %0d", phase_s);
            $fdisplay(fd, "%s - memory_sections: FAIL phase seq @cp2", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 2 pass: .bss array all-zero after startup zero-loop");
          phase_s = 2;
        end

        8'h03: begin
          if (phase_s !== 2) begin
            $display("FAIL: unexpected checkpoint 3 in phase %0d", phase_s);
            $fdisplay(fd, "%s - memory_sections: FAIL phase seq @cp3", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 3 pass: .rodata constant table readable via D-Cache");
          phase_s = 3;
        end

        8'h04: begin
          if (phase_s !== 3) begin
            $display("FAIL: unexpected checkpoint 4 in phase %0d", phase_s);
            $fdisplay(fd, "%s - memory_sections: FAIL phase seq @cp4", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 4 pass: stack push/pop canary survived");
          phase_s = 4;
        end

        8'h05: begin
          if (phase_s !== 4) begin
            $display("FAIL: unexpected checkpoint 5 in phase %0d", phase_s);
            $fdisplay(fd, "%s - memory_sections: FAIL phase seq @cp5", get_time());
            $fclose(fd); $stop;
          end
          $display("Phase 5 pass: heap write/read-back correct");
          phase_s = 5;
        end

        8'h55: begin
          if (phase_s !== 5) begin
            $display("FAIL: final 0x55 before all checkpoints (phase %0d)", phase_s);
            $fdisplay(fd, "%s - memory_sections: FAIL early 0x55", get_time());
            $fclose(fd); $stop;
          end
          $display("Simulation memory_sections PASSED");
          #100; #(1*2*clk_2_t);
          $fdisplay(fd, "%s - memory_sections: Test ok", get_time());
          $fclose(fd); $stop;
        end

        8'hFF: begin
          $display("FAIL: ASM branch-to-fail triggered in phase %0d", phase_s);
          $fdisplay(fd, "%s - memory_sections: Test fail (0xFF)", get_time());
          $fclose(fd); $stop;
        end

        default: begin
          $display("FAIL: unexpected GPIO value 0x%02h in phase %0d", gpio_s[7:0], phase_s);
          $fdisplay(fd, "%s - memory_sections: Test fail (unexpected GPIO)", get_time());
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
