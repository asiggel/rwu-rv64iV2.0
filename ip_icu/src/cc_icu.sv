
// cc_icu.sv
`timescale 1ns/1ps

import as_pack::*;

//-----------------------------------------------------------------------------
// cc_icu - ICU kernel: per-source edge detection + priority arbitration.
// Pure signal processing, no BPI-addressable state -- mirrors the as_gpio.sv /
// as_gpio_top split: the kernel only derives signals from the raw source
// inputs, the "_top" wrapper (cc_icu_top.sv) owns all register storage.
//-----------------------------------------------------------------------------
module cc_icu #( parameter int NUM_SOURCES = icu_num_sources )
               ( input  logic                    rst_i,
                 input  logic                    clk_i,
                 input  logic [NUM_SOURCES-1:0]   irq_src_i,   // raw peripheral IRQ lines (level, same clk domain as clk_i)
                 output logic [NUM_SOURCES-1:0]   irq_pulse_o, // 1-cycle pulse on each rising edge of irq_src_i
                 input  logic [NUM_SOURCES-1:0]   mis_i,       // masked interrupt status (RIS & IMSC), from top
                 input  logic [4*NUM_SOURCES-1:0] prio_i,      // packed 4-bit priority per source, from top
                 input  logic                     gie_i,       // global interrupt enable, from top
                 output logic                     irq_valid_o, // |mis_i, independent of gie_i (for IRQID readback)
                 output logic [2:0]               irq_id_o,    // highest-priority index among mis_i; tie: lowest index
                 output logic                     irq_o        // gie_i & irq_valid_o -> to CPU
               );

  logic [NUM_SOURCES-1:0][1:0] shift_reg_s;

  assign irq_o = gie_i & irq_valid_o;

  //--------------------------------------------
  // Priority arbiter (combinational): among all sources with mis_i=1, the
  // one with the numerically highest prio_i nibble wins. Strict '>' (not
  // '>=') means an equal-priority source never displaces one already found
  // by a lower loop index, which is how the documented "lower index wins
  // ties" rule is implemented.
  //--------------------------------------------
  always_comb
  begin
    logic [3:0] best_prio_v;
    irq_valid_o = |mis_i;
    irq_id_o    = 3'd0;
    best_prio_v = 4'd0;
    for (int i = 0; i < NUM_SOURCES; i++)
    begin
      if (mis_i[i] && (prio_i[4*i +: 4] > best_prio_v))
      begin
        best_prio_v = prio_i[4*i +: 4];
        irq_id_o    = i[2:0];
      end
    end
  end

  //--------------------------------------------
  // Edge detector per source (2-stage shift + rising-edge compare), mirrors
  // as_gpio.sv's shift_reg_s/irq_pulse_s pattern used for GPIO pin-change IRQs.
  // Only the 0->1 transition pulses: a source that is already high when the
  // sticky RIS bit gets cleared in cc_icu_top does NOT re-pulse on its own
  // (see cc_icu_top.sv header comment for why this is the deliberate,
  // race-free alternative to a level-triggered pending bit).
  //--------------------------------------------
  genvar k;
  generate
    for (k = 0; k < NUM_SOURCES; k++)
    begin : g_edge
      always_ff @(posedge clk_i, posedge rst_i)
      begin
        if (rst_i)
        begin
          shift_reg_s[k][0] <= 1'b0;
          shift_reg_s[k][1] <= 1'b0;
        end
        else
        begin
          shift_reg_s[k][0] <= irq_src_i[k];
          shift_reg_s[k][1] <= shift_reg_s[k][0];
        end
      end
      assign irq_pulse_o[k] = shift_reg_s[k][0] & ~shift_reg_s[k][1];
    end
  endgenerate

endmodule : cc_icu
