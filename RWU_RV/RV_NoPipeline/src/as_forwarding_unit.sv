// as_forwarding_unit.sv
`timescale 1ns/1ps
import as_pack::*;
module as_forwarding_unit (
    input  logic [4:0] id_ex_rs1_i,
    input  logic [4:0] id_ex_rs2_i,
    input  logic [4:0] ex_mem_rd_i,
    input  logic       ex_mem_regwr_i,
    input  logic [4:0] mem_wb_rd_i,
    input  logic       mem_wb_regwr_i,
    output logic [1:0] forward_a_o,
    output logic [1:0] forward_b_o
);
    always_comb begin
        forward_a_o = 2'b00;
        forward_b_o = 2'b00;
        if (ex_mem_regwr_i && (ex_mem_rd_i != 5'b0) && (ex_mem_rd_i == id_ex_rs1_i))
            forward_a_o = 2'b10;
        else if (mem_wb_regwr_i && (mem_wb_rd_i != 5'b0) && (mem_wb_rd_i == id_ex_rs1_i))
            forward_a_o = 2'b01;
        if (ex_mem_regwr_i && (ex_mem_rd_i != 5'b0) && (ex_mem_rd_i == id_ex_rs2_i))
            forward_b_o = 2'b10;
        else if (mem_wb_regwr_i && (mem_wb_rd_i != 5'b0) && (mem_wb_rd_i == id_ex_rs2_i))
            forward_b_o = 2'b01;
    end
endmodule : as_forwarding_unit
