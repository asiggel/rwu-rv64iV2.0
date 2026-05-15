`timescale 1ns/1ps

module asScratch #(
    parameter int SP_DEPTH = 1024,   // 64-bit words; must be power of 2
    parameter int PA_WIDTH = 32      // physical address width (unused; for doc)
) (
    input  logic clk_i,
    input  logic rst_i,
    as_dcache_if.cache cpu_if
);

    localparam int ADDR_W = $clog2(SP_DEPTH);

    logic              busy_r;
    logic [2:0]        size_r;
    logic [2:0]        boff_r;
    logic [63:0]       sram_rdata_s;

    logic [ADDR_W-1:0] waddr_s;
    assign waddr_s = cpu_if.dc_addr[ADDR_W+2:3];

    // ── SRAM instance ────────────────────────────────────────────
    // To target ASIC: replace as_sram_sp64 with the X-Fab SRAM wrapper.
    // Port names and protocol are defined in as_sram_sp64.sv.
    as_sram_sp64 #(.DEPTH(SP_DEPTH)) sram (
        .clk_i  (clk_i),
        .cen_i  (cpu_if.dc_req & ~busy_r),
        .we_i   (cpu_if.dc_wr),
        .wbe_i  (cpu_if.dc_wstrb),
        .addr_i (waddr_s),
        .wdata_i(cpu_if.dc_wdata),
        .rdata_o(sram_rdata_s)
    );

    // ── Controller FSM (IDLE / BUSY) ─────────────────────────────
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            busy_r <= 1'b0;
        end else begin
            busy_r <= 1'b0;
            if (!busy_r && cpu_if.dc_req && !cpu_if.dc_wr) begin
                size_r <= cpu_if.dc_size;
                boff_r <= cpu_if.dc_addr[2:0];
                busy_r <= 1'b1;
            end
        end
    end

    // ── CPU interface outputs ────────────────────────────────────
    assign cpu_if.dc_stall      = cpu_if.dc_req & ~cpu_if.dc_wr & ~busy_r;
    assign cpu_if.dc_rvalid     = busy_r;
    assign cpu_if.dc_flush_done = 1'b0;
    assign cpu_if.dc_err        = 1'b0;

    // ── Sign / zero extension (RISC-V dc_size encoding) ─────────
    always_comb begin
        automatic logic [5:0] bsel = {boff_r,        3'b000};
        automatic logic [5:0] hsel = {boff_r[2:1], 4'b0000};
        automatic logic [5:0] wsel = {boff_r[2],  5'b00000};
        case (size_r)
            3'b000: cpu_if.dc_rdata = {{56{sram_rdata_s[bsel+7]}},  sram_rdata_s[bsel +: 8 ]};  // lb
            3'b001: cpu_if.dc_rdata = {{48{sram_rdata_s[hsel+15]}}, sram_rdata_s[hsel +: 16]};  // lh
            3'b010: cpu_if.dc_rdata = {{32{sram_rdata_s[wsel+31]}}, sram_rdata_s[wsel +: 32]};  // lw
            3'b011: cpu_if.dc_rdata = sram_rdata_s;                                               // ld
            3'b100: cpu_if.dc_rdata = {56'h0, sram_rdata_s[bsel +: 8 ]};                        // lbu
            3'b101: cpu_if.dc_rdata = {48'h0, sram_rdata_s[hsel +: 16]};                        // lhu
            3'b110: cpu_if.dc_rdata = {32'h0, sram_rdata_s[wsel +: 32]};                        // lwu
            default: cpu_if.dc_rdata = sram_rdata_s;
        endcase
    end

endmodule : asScratch
