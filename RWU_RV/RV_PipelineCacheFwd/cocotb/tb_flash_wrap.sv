`timescale 1ns/1ps

import as_pack::*;

// cocotb-facing wrapper: as_top_mem + a behavioral QSPI NOR flash model.
//
// RV_PipelineCacheFwd has no directly-pokeable instruction RAM like
// RV_NoPipeline's as_imem.iram_s array — instructions only become visible to
// the CPU through the I-cache's AXI4 fill path from a simulated QSPI flash.
// This wrapper carries that flash model (copied verbatim from
// tb/tb_rv64i_instr.sv's flash_transaction task) so cocotb can load a test
// program by poking flash_mem_s directly, exactly like RV_NoPipeline/cocotb
// pokes imem.iram_s — bypassing JTAG, not bypassing the cache/AXI4 path.
module tb_flash_wrap (
    input  logic clk_i,
    input  logic rst_i,
    input  logic tck_i,
    input  logic trst_i,
    input  logic tms_i,
    input  logic tdi_i,
    output logic tdo_o,
    inout  tri [nr_gpios-1:0] gpio_io,
    output logic cs_o,
    output logic uart0_tx_o,
    input  logic uart0_rx_i,
    output logic clk_div_o
);

  // Flash memory: instructions loaded directly by cocotb (32-bit words)
  localparam int FLASH_WORDS = 16384;
  logic [31:0] flash_mem_s [0:FLASH_WORDS-1];

  logic       sck_s;
  logic       flash_cs_s;
  wire  [3:0] flash_data_s;
  logic [3:0] flash_drive_s = 4'b0;
  logic       flash_oe_s    = 1'b0;
  assign flash_data_s = flash_oe_s ? flash_drive_s : 4'bzzzz;

  as_top_mem DUT (
    .clk_i(clk_i), .rst_i(rst_i),
    .tck_i(tck_i), .trst_i(trst_i), .tms_i(tms_i), .tdi_i(tdi_i), .tdo_o(tdo_o),
    .gpio_io(gpio_io),
    .cs_o(cs_o),
    .sck_o(sck_s),
    .flash_cs_o(flash_cs_s),
    .flash_data_io(flash_data_s),
    .clk_div_o(clk_div_o),
    .uart0_tx_o(uart0_tx_o),
    .uart0_rx_i(uart0_rx_i)
  );

  //------------------------------------------
  // QSPI NOR flash model (W25Q-style, Quad Output Fast Read 0x6B)
  // Copied verbatim from tb/tb_rv64i_instr.sv.
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

endmodule : tb_flash_wrap
