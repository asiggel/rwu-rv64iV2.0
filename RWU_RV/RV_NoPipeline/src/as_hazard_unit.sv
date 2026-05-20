// as_hazard_unit.sv
`timescale 1ns/1ps
import as_pack::*;
module as_hazard_unit (
    input  logic [4:0] if_id_rs1_i,
    input  logic [4:0] if_id_rs2_i,
    input  logic [4:0] id_ex_rd_i,
    input  logic       id_ex_memrd_i,
    input  logic       id_ex_csr_i,
    input  logic       branch_taken_i,
    input  logic       jump_i,
    output logic       stall_if_o,
    output logic       stall_id_o,
    output logic       flush_if_id_o,
    output logic       flush_id_ex_o
);
    logic load_use_hazard_s;
    logic csr_hazard_s;
    logic control_hazard_s;
    assign load_use_hazard_s = id_ex_memrd_i &&
                               (id_ex_rd_i != 5'b0) &&
                               ((id_ex_rd_i == if_id_rs1_i) ||
                                (id_ex_rd_i == if_id_rs2_i));
    assign csr_hazard_s     = id_ex_csr_i;
    assign control_hazard_s = branch_taken_i || jump_i;
    assign stall_if_o    = load_use_hazard_s || csr_hazard_s;
    assign stall_id_o    = load_use_hazard_s || csr_hazard_s;
    assign flush_id_ex_o = load_use_hazard_s || csr_hazard_s || control_hazard_s;
    assign flush_if_id_o = control_hazard_s;
endmodule : as_hazard_unit
