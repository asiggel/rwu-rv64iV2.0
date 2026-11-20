// cc_fetch_unit.sv  –  RV_PipelineCacheFwd: instruction fetch (IF stage)
//
// Contents:
//   PC register        redirect priority: trap > mret > branch > PC+4
//   fetch_pc           PC latched at ic_req, travels with the response
//   fetch in-flight    one outstanding I-cache request at a time
//   discard flag       drops the response of a fetch overtaken by a flush
//   instruction buffer holds a response (or ic_err) while ID is stalled
//
// I-cache handshake: ic_req is a 1-cycle pulse (start_fetch_s); the cache
// answers with ic_rvalid or ic_err. A new request is issued back-to-back on
// the response cycle when ID can accept it, otherwise after the buffered
// instruction has moved on to IF/ID.
`timescale 1ns/1ps

import as_pack::*;

module cc_fetch_unit (
    input  logic                    clk_i,
    input  logic                    rst_i,
    // ── Pipeline control ─────────────────────────────────────────────────────
    input  logic                    flush_i,         // branch (EX) or trap/mret (WB)
    input  logic                    data_stall_i,    // load-use / CSR hazard in ID
    input  logic                    dcache_stall_i,  // load in MEM waiting for D-cache
    // ── Redirect sources ─────────────────────────────────────────────────────
    input  logic                    trap_taken_i,
    input  logic [iaddr_width-1:0]  trap_vec_i,
    input  logic                    mret_i,
    input  logic [iaddr_width-1:0]  mepc_i,
    input  logic                    branch_taken_i,
    input  logic [iaddr_width-1:0]  branch_target_i,
    // ── I-cache ──────────────────────────────────────────────────────────────
    output logic                    ic_req_o,
    output logic [iaddr_width-1:0]  ic_addr_o,
    input  logic                    ic_rvalid_i,
    input  logic                    ic_err_i,
    input  logic [instr_width-1:0]  ic_rdata_i,
    // ── To IF/ID register ────────────────────────────────────────────────────
    output logic [iaddr_width-1:0]  pc_o,
    output logic [iaddr_width-1:0]  fetch_pc_o,
    output logic                    ibuf_valid_o,
    output logic [instr_width-1:0]  ibuf_instr_o,
    output logic [iaddr_width-1:0]  ibuf_pc_o,
    output logic                    ibuf_fault_o,
    output logic                    if_id_advance_o
);

  localparam logic [instr_width-1:0] NOP_INSTR = 32'h00000013;

  logic [iaddr_width-1:0] PC_r;
  logic [iaddr_width-1:0] fetch_pc_r;
  logic                   fetch_in_flight_r;
  logic                   discard_ic_r;
  logic                   rst_deasserted_r;
  logic                   start_fetch_s;
  logic                   if_id_advance_s;

  logic [instr_width-1:0] ibuf_instr_r;
  logic [iaddr_width-1:0] ibuf_pc_r;
  logic                   ibuf_valid_r;
  logic                   ibuf_fault_r;   // buffered fetch was an ic_err, not a real instruction

  // ─── assign statements ───────────────────────────────────────────────────

  assign start_fetch_s =
    (rst_deasserted_r && !fetch_in_flight_r && !ibuf_valid_r && !flush_i)
    ||
    (rst_deasserted_r && ic_rvalid_i && !discard_ic_r && !ibuf_valid_r &&
     !data_stall_i && !dcache_stall_i && !flush_i);

  assign if_id_advance_s = (ibuf_valid_r ||
                             ((ic_rvalid_i || ic_err_i) && !discard_ic_r))
                           && !data_stall_i && !dcache_stall_i;

  assign ic_req_o        = start_fetch_s;
  assign ic_addr_o       = PC_r;
  assign pc_o            = PC_r;
  assign fetch_pc_o      = fetch_pc_r;
  assign ibuf_valid_o    = ibuf_valid_r;
  assign ibuf_instr_o    = ibuf_instr_r;
  assign ibuf_pc_o       = ibuf_pc_r;
  assign ibuf_fault_o    = ibuf_fault_r;
  assign if_id_advance_o = if_id_advance_s;

  // ─── always_ff blocks ────────────────────────────────────────────────────

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      PC_r <= 64'h0;
    else begin
      if      (trap_taken_i)   PC_r <= trap_vec_i;
      else if (mret_i)         PC_r <= mepc_i;
      else if (branch_taken_i) PC_r <= branch_target_i;
      else if (start_fetch_s)  PC_r <= PC_r + 64'd4;
    end
  end

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)              fetch_pc_r <= 64'h0;
    else if (start_fetch_s) fetch_pc_r <= PC_r;
  end

  // A flush does not end an outstanding fetch: the I-cache accepts ic_req only
  // in IDLE_ST, so a new request issued while the old miss is still being
  // filled would be ignored, and the old (discarded) response would then be
  // taken as the end of the new fetch -- the first instruction at the trap
  // vector / mret target was lost. The new fetch starts after the discarded
  // response instead.
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      fetch_in_flight_r <= 1'b0;
    else begin
      if      (start_fetch_s)          fetch_in_flight_r <= 1'b1;
      else if (ic_rvalid_i || ic_err_i) fetch_in_flight_r <= 1'b0;
    end
  end

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i)
      discard_ic_r <= 1'b0;
    else begin
      if      (flush_i && fetch_in_flight_r && !ic_rvalid_i && !ic_err_i) discard_ic_r <= 1'b1;
      else if ((ic_rvalid_i || ic_err_i) && discard_ic_r)                discard_ic_r <= 1'b0;
    end
  end

  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) begin
      ibuf_valid_r <= 1'b0;
      ibuf_instr_r <= NOP_INSTR;
      ibuf_pc_r    <= 64'h0;
      ibuf_fault_r <= 1'b0;
    end else begin
      if (flush_i) begin
        ibuf_valid_r <= 1'b0;
      end else if (ic_rvalid_i && !discard_ic_r &&
                   (data_stall_i || dcache_stall_i)) begin
        ibuf_instr_r <= ic_rdata_i;
        ibuf_pc_r    <= fetch_pc_r;
        ibuf_fault_r <= 1'b0;
        ibuf_valid_r <= 1'b1;
      end else if (ic_err_i && !discard_ic_r &&
                   (data_stall_i || dcache_stall_i)) begin
        // Downstream is stalled: buffer the fault (as a NOP placeholder)
        // exactly like a successful fetch, so it is not lost.
        ibuf_instr_r <= NOP_INSTR;
        ibuf_pc_r    <= fetch_pc_r;
        ibuf_fault_r <= 1'b1;
        ibuf_valid_r <= 1'b1;
      end else if (ibuf_valid_r && if_id_advance_s) begin
        ibuf_valid_r <= 1'b0;
      end
    end
  end

  // Suppresses fetch while reset is asserted (rst_i must not be used as data).
  always_ff @(posedge clk_i, posedge rst_i) begin
    if (rst_i) rst_deasserted_r <= 1'b0;
    else       rst_deasserted_r <= 1'b1;
  end

endmodule : cc_fetch_unit
