// cc_mem_unit.sv  –  RV_PipelineCacheFwd: memory access (MEM stage)
//
// Contents:
//   D-cache request    address / size / write data from the EX/MEM register
//   dc_req one-shot    one request per instruction while the pipe is stalled
//   read-data buffer   keeps dc_rdata / dc_err until the pipe advances
//
// The D-cache answers a load with a 1-cycle dc_rvalid or dc_err pulse.
// While global_stall_i is held by another cause (e.g. a concurrent I-cache
// miss) the MEM/WB register does not load, so the pulse would be lost:
// it is latched here and released when the pipe advances.
`timescale 1ns/1ps

import as_pack::*;

module cc_mem_unit (
    input  logic                    clk_i,
    input  logic                    rst_i,
    // ── Pipeline control ─────────────────────────────────────────────────────
    input  logic                    global_stall_i,
    input  logic                    flush_back_i,     // trap/mret in WB
    // ── EX/MEM register ──────────────────────────────────────────────────────
    input  logic                    valid_i,
    input  logic                    dMemRd_i,
    input  logic                    dMemWr_i,
    input  logic                    trap_misaligned_i,
    input  logic [2:0]              funct3_i,         // access size / signedness
    input  logic [reg_width-1:0]    addr_i,
    input  logic [63:0]             wdata_i,
    input  logic [7:0]              wstrb_i,
    // ── D-cache ──────────────────────────────────────────────────────────────
    output logic                    dc_req_o,
    output logic                    dc_wr_o,
    output logic [2:0]              dc_size_o,
    output logic [63:0]             dc_addr_o,
    output logic [63:0]             dc_wdata_o,
    output logic [7:0]              dc_wstrb_o,
    input  logic                    dc_rvalid_i,
    input  logic                    dc_err_i,
    input  logic [reg_width-1:0]    dc_rdata_i,
    // ── Buffered response (to cc_hazard_unit / cc_mem_wb_reg) ────────────────
    output logic [reg_width-1:0]    rdata_buf_o,
    output logic                    rdata_buf_valid_o,
    output logic                    err_buf_o
);

  localparam int XLEN = reg_width;

  logic                 dc_req_s;
  logic                 dc_req_sent_r;
  logic [reg_width-1:0] rdata_buf_r;
  logic                 rdata_buf_valid_r;
  logic                 err_buf_r;

  // ─── assign statements ───────────────────────────────────────────────────

  // Precise traps: no memory access for a misaligned load/store, and none
  // for the (younger) MEM instruction while WB traps or returns.
  assign dc_req_s = valid_i && (dMemRd_i || dMemWr_i) &&
                    !trap_misaligned_i && !flush_back_i && !dc_req_sent_r;

  assign dc_req_o          = dc_req_s;
  assign dc_wr_o           = dMemWr_i;
  assign dc_size_o         = funct3_i;
  assign dc_addr_o         = addr_i;
  assign dc_wdata_o        = wdata_i;
  assign dc_wstrb_o        = wstrb_i;
  assign rdata_buf_o       = rdata_buf_r;
  assign rdata_buf_valid_o = rdata_buf_valid_r;
  assign err_buf_o         = err_buf_r;

  // ─── always_ff blocks ────────────────────────────────────────────────────

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      dc_req_sent_r <= 1'b0;
    else begin
      if (!global_stall_i) dc_req_sent_r <= 1'b0;
      else if (dc_req_s)   dc_req_sent_r <= 1'b1;
    end
  end

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      rdata_buf_valid_r <= 1'b0;
      rdata_buf_r       <= {XLEN{1'b0}};
      err_buf_r         <= 1'b0;
    end else begin
      if (!global_stall_i) begin
        rdata_buf_valid_r <= 1'b0;
        err_buf_r         <= 1'b0;
      end else if (dc_rvalid_i && valid_i && dMemRd_i && !rdata_buf_valid_r) begin
        rdata_buf_r       <= dc_rdata_i;
        rdata_buf_valid_r <= 1'b1;
      end else if (dc_err_i && valid_i && dMemRd_i &&
                   !rdata_buf_valid_r && !err_buf_r) begin
        err_buf_r <= 1'b1;
      end
    end
  end

endmodule : cc_mem_unit
