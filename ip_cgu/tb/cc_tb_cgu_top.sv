// cc_tb_cgu_top.sv - unit test for as_cgu_top
//
// Checks that the ID register is written on clk_wb_i (the Wishbone master
// clock) and not on clk_i, plus reset value, byte-select and address
// decoding, and the clk_core_o divide ratio.
`timescale 1ns/1ps

import as_pack::*;

module cc_tb_cgu_top;

  localparam logic [63:0] WR_VAL_C = 64'hDEAD_BEEF_CAFE_F00D;

  logic                      clk_s;
  logic                      rst_s;
  logic                      clk_core_s;
  logic [cgu_addr_width-1:0] addr_s;
  logic [reg_width-1:0]      wdat_s;
  logic [reg_width-1:0]      rdat_s;
  logic                      we_s;
  logic [wbdSel-1:0]         sel_s;
  logic                      stb_s;
  logic                      cyc_s;
  logic                      ack_s;
  int                        errors_s;
  realtime                   t_rise1_s;
  realtime                   t_rise2_s;
  logic [63:0]               rd_v;

  // The CPU runs on clk_core_o in the chip, so the bus does here as well.
  as_cgu_top #(cgu_addr_width) dut (
    .clk_i(clk_s), .clk_wb_i(clk_core_s), .rst_i(rst_s),
    .wbdAddr_i(addr_s), .wbdDat_i(wdat_s), .wbdDat_o(rdat_s),
    .wbdWe_i(we_s), .wbdSel_i(sel_s), .wbdStb_i(stb_s),
    .wbdAck_o(ack_s), .wbdCyc_i(cyc_s),
    .clk_bus1_o(), .clk_bus2_o(), .clk_qspi_o(),
    .clk_core_o(clk_core_s));

  initial clk_s = 1'b0;
  always #5 clk_s = ~clk_s;

  task automatic check(input string what, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%016h, expected 0x%016h", what, got, exp);
      errors_s++;
    end else
      $display("ok   %s: 0x%016h", what, got);
  endtask

  task automatic bus_idle();
    stb_s = 1'b0; cyc_s = 1'b0; we_s = 1'b0; sel_s = '0;
    addr_s = '0; wdat_s = '0;
  endtask

  // Drives one write for a whole clk_wb_i cycle, as the CPU does.
  task automatic bus_write(input logic [cgu_addr_width-1:0] a, input logic [63:0] d,
                           input logic [wbdSel-1:0] sel);
    @(posedge clk_core_s); #1;
    addr_s = a; wdat_s = d; sel_s = sel; we_s = 1'b1; stb_s = 1'b1; cyc_s = 1'b1;
    @(posedge clk_core_s); #1;
    bus_idle();
  endtask

  task automatic bus_read(input logic [cgu_addr_width-1:0] a, output logic [63:0] d);
    @(posedge clk_core_s); #1;
    addr_s = a; sel_s = '1; we_s = 1'b0; stb_s = 1'b1; cyc_s = 1'b1;
    #10;
    d = rdat_s;
    @(posedge clk_core_s); #1;
    bus_idle();
  endtask

  initial begin
    errors_s = 0;
    bus_idle();
    rst_s = 1'b1;
    #23 rst_s = 1'b0;

    bus_read(cgu_id_reg_addr_offs_c[cgu_addr_width-1:0], rd_v);
    check("reset value", rd_v, cgu_id_reg_addr_rst_c);

    // Many clk_i edges pass while the write is on the bus; the register
    // must only change with the clk_wb_i edge that ends the write cycle.
    @(posedge clk_core_s); #1;
    addr_s = cgu_id_reg_addr_offs_c[cgu_addr_width-1:0];
    wdat_s = WR_VAL_C; sel_s = '1; we_s = 1'b1; stb_s = 1'b1; cyc_s = 1'b1;
    #1 check("ack during write", {63'b0, ack_s}, 64'd1);
    repeat (78) @(posedge clk_s);
    #1 check("no update on clk_i edges", dut.id_reg_r, cgu_id_reg_addr_rst_c);
    @(posedge clk_core_s); #1;
    check("update on clk_wb_i edge", dut.id_reg_r, WR_VAL_C);
    bus_idle();

    bus_read(cgu_id_reg_addr_offs_c[cgu_addr_width-1:0], rd_v);
    check("read back", rd_v, WR_VAL_C);

    bus_write(cgu_id_reg_addr_offs_c[cgu_addr_width-1:0], 64'h1111, 8'h0F);
    bus_read(cgu_id_reg_addr_offs_c[cgu_addr_width-1:0], rd_v);
    check("partial sel ignored", rd_v, WR_VAL_C);

    bus_write(8'h08, 64'h2222, '1);
    bus_read(cgu_id_reg_addr_offs_c[cgu_addr_width-1:0], rd_v);
    check("other address ignored", rd_v, WR_VAL_C);
    bus_read(8'h08, rd_v);
    check("unmapped address reads 0", rd_v, 64'h0);

    @(posedge clk_core_s); t_rise1_s = $realtime;
    @(posedge clk_core_s); t_rise2_s = $realtime;
    check("clk_core_o period [ns]", 64'(int'(t_rise2_s - t_rise1_s)), 64'(clk_core_div * 10));

    if (errors_s == 0) $display("CGU unit test PASSED");
    else               $display("CGU unit test FAILED: %0d error(s)", errors_s);
    $finish;
  end

endmodule : cc_tb_cgu_top
