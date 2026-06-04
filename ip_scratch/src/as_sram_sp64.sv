// as_sram_sp64.sv  –  Single-port 64-bit SRAM — behavioral model (FPGA / simulation)
//
// ASIC target: replace this file with a wrapper around the X-Fab SRAM macro.
// Keep the port list identical; map internal signals to macro pins as shown below.
//
// Typical X-Fab single-port SRAM macro pin mapping:
//   clk_i   → CLK
//   cen_i   → ~CEN   (macro: active-low chip enable)
//   we_i    → ~WEN   (macro: active-low write enable)
//   wbe_i   → ~BWEN  (macro: active-low bit-write enable, replicate byte→8 bits each)
//   addr_i  → A
//   wdata_i → D
//   rdata_o ← Q      (registered, valid 1 cycle after read)
//
// Interface contract (active-high):
//   cen_i=1, we_i=1 : write  wdata_i[bytes selected by wbe_i] to addr_i
//   cen_i=1, we_i=0 : read   addr_i; rdata_o valid on the following rising edge
//   cen_i=0         : no access; rdata_o retains last value
`timescale 1ns/1ps

module as_sram_sp64 #(
    parameter int DEPTH = 1024   // number of 64-bit words; must be power of 2
) (
    input  logic                     clk_i,
    input  logic                     cen_i,    // chip enable, active high
    input  logic                     we_i,     // 1 = write, 0 = read
    input  logic [7:0]               wbe_i,    // byte write enables, active high
    input  logic [$clog2(DEPTH)-1:0] addr_i,
    input  logic [63:0]              wdata_i,
    output logic [63:0]              rdata_o   // registered; valid 1 cycle after read
);

    // FPGA: infer Block RAM (ASIC flow replaces this module with X-Fab macro wrapper)
    (* ram_style = "block" *) logic [63:0] mem [0:DEPTH-1];

    always_ff @(posedge clk_i) begin
        if (cen_i) begin
            if (we_i) begin
                for (int i = 0; i < 8; i++)
                    if (wbe_i[i]) mem[addr_i][i*8 +: 8] <= wdata_i[i*8 +: 8];
            end else begin
                rdata_o <= mem[addr_i];
            end
        end
    end

endmodule : as_sram_sp64
