
// cc_icu_top.sv
`timescale 1ns/1ps

import as_pack::*;

//-----------------------------------------------------------------------------
// Wishbone slave: ICU (Interrupt Control Unit)
//
// Aggregates NUM_SOURCES peripheral interrupt lines into the single external
// interrupt bit consumed by the CPU (irq_ext_i[7] on both as_cpux and
// cc_cpupipefwd), with per-source masking, software-configurable priority,
// and a cause-identification register so firmware does not have to poll
// every peripheral's own MIS register to find out who interrupted.
//
// Pending-bit semantics (RIS): edge-triggered and sticky, exactly like
// GPIO0's IRQSS / UART0's RIS. A source's raw IRQ line is treated as a level
// (it stays high until the *peripheral's own* cause is cleared); the ICU
// itself only latches the 0->1 transition into a sticky bit that firmware
// then clears explicitly via ICR. This is deliberately NOT a level
// pass-through of the source line: a level-based design has a race where a
// software clear (ICR) issued in the same cycle a fresh interrupt re-arrives
// can lose the new occurrence. The edge/sticky design still has one
// coincidence case -- a hardware edge (or SW-forced ISR write) landing in
// the same cycle as an ICR write to the same bit -- and resolves it by
// giving SET priority over CLEAR (see the RIS always_ff below), so a real
// interrupt is never silently dropped.
//-----------------------------------------------------------------------------
module cc_icu_top #( parameter int ICU_ADDR_WIDTH = 64,
                     parameter int ICU_DATA_WIDTH = 64,
                     parameter int NUM_SOURCES    = icu_num_sources )
                   ( input  logic                      rst_i,
                     input  logic                      clk_i,
                     // wishbone side
                     input  logic [ICU_ADDR_WIDTH-1:0] wbdAddr_i,
                     input  logic [reg_width-1:0]      wbdDat_i,
                     output logic [reg_width-1:0]      wbdDat_o,
                     input  logic                      wbdWe_i,
                     input  logic [wbdSel-1:0]         wbdSel_i,
                     input  logic                      wbdStb_i,
                     output logic                      wbdAck_o,
                     input  logic                      wbdCyc_i,
                     // interrupt sources / CPU-facing output
                     input  logic [NUM_SOURCES-1:0]    irq_src_i,
                     output logic                      icu_irq_o
                   );

  // address, data, enable (from BPI)
  logic [ICU_ADDR_WIDTH-1:0] addr_s;
  logic [reg_width-1:0]      data_s;    // data from bus/BPI to kernel/registers
  logic [reg_width-1:0]      dataob_s;  // data from registers to BPI/bus
  logic                      en_s;      // write enable, from BPI

  // kernel signals
  logic [NUM_SOURCES-1:0]    irq_pulse_s;
  logic [NUM_SOURCES-1:0]    mis_comb_s;
  logic                      irq_valid_s;
  logic [2:0]                irq_id_s;

  // registers
  logic [reg_width-1:0]      id_reg_s;     // ICU peripheral ID-register (ro);              address=0  (0x00)
  logic [NUM_SOURCES-1:0]    ris_reg_s;    // Raw Interrupt Status, sticky, 1 bit/source;    address=8  (0x08)
  logic [NUM_SOURCES-1:0]    imsc_reg_s;   // Interrupt Mask Control, 1 bit/source;          address=16 (0x10)
  logic [NUM_SOURCES-1:0]    mis_reg_s;    // Masked Interrupt Status (registered readback); address=24 (0x18)
  // ICR/ISR (address=32/40, 0x20/0x28) are write-only strobes, not stored (see wr_icr_s/wr_isr_s below)
  logic [4*NUM_SOURCES-1:0]  prio_reg_s;   // 4-bit priority per source, packed;              address=48 (0x30)
  logic [reg_width-1:0]      irqid_s;      // IRQID readback (combinational, not a register); address=56 (0x38)
  logic                      ctrl_gie_r;   // CTRL[0] = GIE, global interrupt enable;         address=64 (0x40)

  logic                      wr_icr_s, wr_isr_s;

  //--------------------------------------------
  // ID: constant, true read-only (no write branch). GPIO0's own ID register
  // is nominally rw in RTL despite being documented ro in the spec -- an
  // existing minor inconsistency in this codebase that is not replicated here.
  //--------------------------------------------
  assign id_reg_s = icu_id_reg_rst_c;

  //--------------------------------------------
  // ICR / ISR: write-only strobes (not stored), decoded straight from the BPI
  //--------------------------------------------
  assign wr_icr_s = en_s & (addr_s == icu_icr_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]);
  assign wr_isr_s = en_s & (addr_s == icu_isr_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]);

  //--------------------------------------------
  // MIS: mis_comb_s is combinational (drives the kernel arbiter with no
  // extra latency); mis_reg_s (below) is a registered copy for register
  // readback only -- same split as GPIO0's irq_mis_s (comb) vs mis_reg_s
  // (registered).
  //--------------------------------------------
  assign mis_comb_s = ris_reg_s & imsc_reg_s;

  //--------------------------------------------
  // IRQID: combinational readback, bit[3]=VALID, bits[2:0]=id. VALID is a
  // separate bit rather than encoding "no IRQ" as id==0, because id==0 is
  // also GPIO0's real source index -- collapsing "none" onto a real id would
  // make the register ambiguous (exactly the kind of bug this ICU is meant
  // to avoid; see README_IMPL for the contrast with the graded reference
  // student submission that had a similar 0-as-sentinel issue).
  //--------------------------------------------
  assign irqid_s = {{(reg_width-4){1'b0}}, irq_valid_s, irq_id_s};

  //--------------------------------------------
  // Read mux
  //--------------------------------------------
  always_comb
  begin
    case (addr_s)
      icu_id_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]    : dataob_s = id_reg_s;
      icu_ris_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]   : dataob_s = {{(reg_width-NUM_SOURCES){1'b0}}, ris_reg_s};
      icu_imsc_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]  : dataob_s = {{(reg_width-NUM_SOURCES){1'b0}}, imsc_reg_s};
      icu_mis_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]   : dataob_s = {{(reg_width-NUM_SOURCES){1'b0}}, mis_reg_s};
      icu_icr_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]   : dataob_s = '0; // write-only, reads as 0
      icu_isr_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]   : dataob_s = '0; // write-only, reads as 0
      icu_prio_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]  : dataob_s = {{(reg_width-4*NUM_SOURCES){1'b0}}, prio_reg_s};
      icu_irqid_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0] : dataob_s = irqid_s;
      icu_ctrl_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]  : dataob_s = {{(reg_width-1){1'b0}}, ctrl_gie_r};
      default                                        : dataob_s = '0;
    endcase
  end

  //--------------------------------------------
  // IMSC: rw, per-source mask enable
  //--------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      imsc_reg_s <= icu_imsc_reg_rst_c[NUM_SOURCES-1:0];
    else
      if (en_s & (addr_s == icu_imsc_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]))
        imsc_reg_s <= data_s[NUM_SOURCES-1:0];
  end

  //--------------------------------------------
  // MIS: registered readback copy (see mis_comb_s assign above)
  //--------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      mis_reg_s <= '0;
    else
      mis_reg_s <= mis_comb_s;
  end

  //--------------------------------------------
  // PRIO: rw, 4-bit priority nibble per source, packed
  //--------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      prio_reg_s <= icu_prio_reg_rst_c[4*NUM_SOURCES-1:0];
    else
      if (en_s & (addr_s == icu_prio_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]))
        prio_reg_s <= data_s[4*NUM_SOURCES-1:0];
  end

  //--------------------------------------------
  // CTRL: rw, bit[0] = GIE (global interrupt enable)
  //--------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      ctrl_gie_r <= icu_ctrl_reg_rst_c[0];
    else
      if (en_s & (addr_s == icu_ctrl_reg_addr_offs_c[ICU_ADDR_WIDTH-1:0]))
        ctrl_gie_r <= data_s[0];
  end

  //--------------------------------------------
  // RIS: sticky, edge-triggered pending bits (see module header for the
  // race-free SET-over-CLEAR coincidence rule)
  //--------------------------------------------
  genvar b;
  generate
    for (b = 0; b < NUM_SOURCES; b++)
    begin : g_ris
      always_ff @(posedge clk_i, posedge rst_i)
      begin
        if (rst_i)
          ris_reg_s[b] <= icu_ris_reg_rst_c[b];
        else if (irq_pulse_s[b] || (wr_isr_s && data_s[b]))
          ris_reg_s[b] <= 1'b1;
        else if (wr_icr_s && data_s[b])
          ris_reg_s[b] <= 1'b0;
      end
    end
  endgenerate

  //--------------------------------------------
  // Slave BPI
  //--------------------------------------------
  as_slave_bpi #(ICU_ADDR_WIDTH, ICU_DATA_WIDTH)
                            sIcuBpi(.rst_i(rst_i),
                                    .clk_i(clk_i),
                                    .addr_o(addr_s),
                                    .dat_from_core_i(dataob_s),
                                    .dat_to_core_o(data_s),
                                    .wr_o(en_s),
                                    .rd_o(),
                                    .wb_s_addr_i(wbdAddr_i),
                                    .wb_s_dat_i(wbdDat_i),
                                    .wb_s_dat_o(wbdDat_o),
                                    .wb_s_we_i(wbdWe_i),
                                    .wb_s_sel_i(wbdSel_i),
                                    .wb_s_stb_i(wbdStb_i),
                                    .wb_s_ack_o(wbdAck_o),
                                    .wb_s_cyc_i(wbdCyc_i)
                                   );

  //--------------------------------------------
  // Peripheral kernel: edge detection + priority arbitration
  //--------------------------------------------
  cc_icu #(NUM_SOURCES) myicu (.rst_i(rst_i),
                               .clk_i(clk_i),
                               .irq_src_i(irq_src_i),
                               .irq_pulse_o(irq_pulse_s),
                               .mis_i(mis_comb_s),
                               .prio_i(prio_reg_s),
                               .gie_i(ctrl_gie_r),
                               .irq_valid_o(irq_valid_s),
                               .irq_id_o(irq_id_s),
                               .irq_o(icu_irq_o)
                              );

endmodule : cc_icu_top
