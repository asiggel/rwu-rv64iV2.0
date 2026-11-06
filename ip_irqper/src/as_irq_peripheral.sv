// as_irq_peripheral.sv
`timescale 1ns/1ps

/*
as_irq_peripheral - shared interrupt register block for all peripherals
=======================================================================

Every peripheral (GPIO, UART, ...) has the same set of interrupt registers.
Instead of writing them again in each peripheral, the peripheral top
instantiates this block and connects it to its slave BPI
(addr_i, data_i, en_i) and to the interrupt events of its kernel.

Interrupt events
  The kernel detects an event (edge, threshold, error, ...) and delivers a
  pulse that is exactly ONE clock cycle long. Whether the event is a rising
  edge, a falling edge or a level is decided in the kernel, not here.
  This block only stores the pulse until software has handled it.

Register set (offsets are set per peripheral by parameters)
  Name   Mode  Stored?  Function
  RIS    r     yes      Raw Interrupt Status: 1 = event happened (pending)
  IMSC   rw    yes      Interrupt Mask: 1 = this RIS bit may raise irq_o
  MIS    r     no       Masked Interrupt Status = RIS & IMSC
  ICR    w     no       Interrupt Clear: writing 1 clears the RIS bit
  ISR    w     no       Interrupt Set:   writing 1 sets the RIS bit (SW test)
  -- only if irqs_yes_no = 1 --
  IRQSS  r     yes      Source Status: one bit per source of the same type
  IRQSM  rw    yes      Source Mask:   1 = this source contributes to RIS[0]
  IRQSC  w     no       Source Clear:  writing 1 clears the IRQSS bit

  "Stored? no" means: there is no flip-flop. ICR, ISR and IRQSC are only
  write strobes that act in the cycle of the bus write; reading them
  returns 0. MIS is computed from RIS and IMSC.
  All write-1 registers work bit by bit: a 0 in the written data leaves the
  corresponding bit unchanged.

Two variants, selected by irqs_yes_no
  irqs_yes_no = 0: only different IRQs (e.g. UART: rx_ready, tx_ready, ...)
      irq_other_i[n] -> RIS[n]
      IRQSS/IRQSM/IRQSC do not exist; their addresses are not decoded.

  irqs_yes_no = 1: several IRQs of the same type (e.g. GPIO: one per pin)
      irq_same_i[k] -> IRQSS[k] --(& IRQSM)--> OR --> RIS[0]
      irq_other_i[n] -> RIS[n+1]
      RIS[0] is NOT stored separately; it is the level |(IRQSS & IRQSM),
      so writing IRQSC is enough to clear the group interrupt.
      ICR[0] only clears a bit 0 that was forced by software via ISR.

Signal flow (irqs_yes_no = 1)

  irq_same_i --> IRQSS --&--> OR --+
                 IRQSM --'         |
                                   v
  irq_other_i -------------------> RIS --&--> MIS --> OR --> irq_o
  ISR (write 1 = set) -----------> RIS    |
  ICR (write 1 = clear) ---------> RIS  IMSC

Software sequence in an interrupt service routine
  1. read MIS (and IRQSS for a group) to find the source(s)
  2. handle the source(s)
  3. write 1s to IRQSC (group) and/or ICR (other IRQs) for every handled bit
  4. if MIS is still not 0, go back to 1
  Step 4 matters because the ICU only reacts to a rising edge of irq_o:
  if one source stays pending, irq_o stays 1 and no new edge is generated.

Naming: _i input, _o output, _r flip-flop (register), _s combinational signal

Restrictions
  nr_other_irqs >= 1 (a port of width 0 is not allowed; tie unused inputs to 0)
  nr_other_irqs + 1 <= data_width if irqs_yes_no = 1, else nr_other_irqs <= data_width
  nr_same_irqs <= data_width
  All used address offsets must be different from each other and from the
  other registers of the peripheral.
 */

module as_irq_peripheral #(parameter int          addr_width      = 64, // width of addr_i, as delivered by the slave BPI
                           parameter int          data_width      = 64, // register width (= bus data width)
                           parameter int          nr_other_irqs   = 8,  // number of different IRQs  -> RIS bits
                           parameter int          nr_same_irqs    = 8,  // number of IRQs of one type -> IRQSS bits
                           parameter int          irqs_yes_no     = 0,  // 1: IRQSS/IRQSM/IRQSC exist, 0: they do not
                           parameter logic [63:0] reg_irqsm_rst   = '0, // reset value of IRQSM
                           parameter logic [63:0] reg_imsc_rst    = '0, // reset value of IMSC
                           parameter logic [63:0] addr_offs_irqss = 0,  // address offsets inside the peripheral
                           parameter logic [63:0] addr_offs_irqsc = 0,
                           parameter logic [63:0] addr_offs_irqsm = 0,
                           parameter logic [63:0] addr_offs_imsc  = 0,
                           parameter logic [63:0] addr_offs_ris   = 0,
                           parameter logic [63:0] addr_offs_isr   = 0,
                           parameter logic [63:0] addr_offs_icr   = 0,
                           parameter logic [63:0] addr_offs_mis   = 0
                          )
                          ( input  logic                     rst_i,       // asynchronous reset, active high
                            input  logic                     clk_i,
                            input  logic                     en_i,        // write enable from the BPI (bus write cycle)
                            input  logic [nr_other_irqs-1:0] irq_other_i, // 1-cycle event pulses, different IRQs
                            /* verilator lint_off UNUSEDSIGNAL */ // unused if irqs_yes_no = 0
                            input  logic [nr_same_irqs-1:0]  irq_same_i,  // 1-cycle event pulses, IRQs of the same type
                            /* verilator lint_on UNUSEDSIGNAL */
                            input  logic [addr_width-1:0]    addr_i,      // register address offset from the BPI
                            input  logic [data_width-1:0]    data_i,      // write data from the BPI
                            output logic [data_width-1:0]    data_o,      // read data; 0 for all other addresses
                            output logic [data_width-1:0]    ris_o,       // RIS, e.g. to mirror bits into a status register
                            output logic                     irq_o        // interrupt request to the ICU
                          );

  // With a group of same-type IRQs, RIS[0] is reserved for the group and the
  // other IRQs start at RIS[1]; otherwise they start at RIS[0].
  localparam int ris_lsb_c = (irqs_yes_no == 1) ? 1 : 0;

  // Flip-flops: RIS, IMSC, IRQSS, IRQSM.
  // MIS, ICR, ISR and IRQSC have no flip-flop (see header).
  logic [data_width-1:0] ris_r;           // stored part of RIS (events, ISR)
  logic [data_width-1:0] imsc_r;
  logic [data_width-1:0] irqss_r;
  logic [data_width-1:0] irqsm_r;
  logic [data_width-1:0] ris_s;           // RIS as seen by software: ris_r plus group level in bit 0
  logic [data_width-1:0] mis_s;
  logic [data_width-1:0] ris_set_s;       // bits to be set in ris_r in this cycle
  logic [data_width-1:0] ris_clr_s;       // bits to be cleared in ris_r in this cycle
  logic                  irq_same_comb_s; // at least one same-type IRQ pending and not masked

  // Write strobes: 1 only in the clock cycle in which the bus writes this register
  logic                  wr_imsc_s;
  logic                  wr_isr_s;
  logic                  wr_icr_s;

  assign wr_imsc_s  = en_i & (addr_i == addr_offs_imsc[addr_width-1:0]);
  assign wr_isr_s   = en_i & (addr_i == addr_offs_isr[addr_width-1:0]);
  assign wr_icr_s   = en_i & (addr_i == addr_offs_icr[addr_width-1:0]);

  // First bitwise AND (mask each source), then OR all bits together.
  assign irq_same_comb_s = |(irqss_r & irqsm_r);

  // Set sources of RIS: the event pulses of the different IRQs, placed at
  // their RIS positions, plus the bits that software writes as 1 to ISR.
  always_comb
  begin
    ris_set_s                             = '0;
    ris_set_s[ris_lsb_c +: nr_other_irqs] = irq_other_i;
    if (wr_isr_s)
      ris_set_s                           = ris_set_s | data_i;
  end

  // ICR: only the bits written as 1 are cleared, and only in the write cycle.
  assign ris_clr_s = wr_icr_s ? data_i : '0;
  // Bit 0 of the same-type group is a level: IRQSS already holds the sticky
  // state, so storing it a second time in RIS would only need a second clear.
  assign ris_s     = ris_r | {{(data_width-1){1'b0}}, irq_same_comb_s};
  assign mis_s     = ris_s & imsc_r;
  assign ris_o     = ris_s;
  assign irq_o     = |mis_s;

  // RIS: a bit stays 1 (sticky) until it is cleared by ICR.
  // Set wins over clear: if a new event arrives in the same cycle in which
  // software clears the previous one, the new event must not be lost.
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      ris_r <= '0;
    else
      ris_r <= (ris_r & ~ris_clr_s) | ris_set_s;
  end

  // IMSC: normal read/write register
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if (rst_i)
      imsc_r <= reg_imsc_rst[data_width-1:0];
    else if (wr_imsc_s)
      imsc_r <= data_i;
  end

  // IRQSS/IRQSM/IRQSC are only built in hardware if irqs_yes_no = 1.
  generate
    if (irqs_yes_no == 1)
    begin : g_same_irqs
      logic wr_irqsc_s;
      logic wr_irqsm_s;

      assign wr_irqsc_s = en_i & (addr_i == addr_offs_irqsc[addr_width-1:0]);
      assign wr_irqsm_s = en_i & (addr_i == addr_offs_irqsm[addr_width-1:0]);

      // IRQSS: one sticky bit per source. New pulses are ORed in (never
      // overwrite, so an earlier pending source is not lost); IRQSC clears
      // only the bits written as 1. Set wins over clear, as for RIS.
      always_ff @(posedge clk_i, posedge rst_i)
      begin
        if (rst_i)
          irqss_r <= '0;
        else
          irqss_r <= (irqss_r & ~(wr_irqsc_s ? data_i : '0))
                   | {{(data_width-nr_same_irqs){1'b0}}, irq_same_i};
      end

      // IRQSM: normal read/write register
      always_ff @(posedge clk_i, posedge rst_i)
      begin
        if (rst_i)
          irqsm_r <= reg_irqsm_rst[data_width-1:0];
        else if (wr_irqsm_s)
          irqsm_r <= data_i;
      end
    end
    else
    begin : g_no_same_irqs
      // Constant 0: no flip-flops are synthesized, RIS[0] gets no group level.
      assign irqss_r = '0;
      assign irqsm_r = '0;
    end
  endgenerate

  // Read multiplexer. IRQSC, ISR and ICR are not stored and therefore read 0,
  // as do all addresses that do not belong to this block. The peripheral top
  // decides which addresses it forwards to data_o.
  // if-chain instead of case: in the variant irqs_yes_no = 0 the unused
  // IRQSS/IRQSM offsets may have the same value as other registers.
  always_comb
  begin
    data_o = '0;
    if (addr_i == addr_offs_imsc[addr_width-1:0]) data_o = imsc_r;
    if (addr_i == addr_offs_ris[addr_width-1:0])  data_o = ris_s;
    if (addr_i == addr_offs_mis[addr_width-1:0])  data_o = mis_s;
    if (irqs_yes_no == 1)
    begin
      if (addr_i == addr_offs_irqss[addr_width-1:0]) data_o = irqss_r;
      if (addr_i == addr_offs_irqsm[addr_width-1:0]) data_o = irqsm_r;
    end
  end

endmodule : as_irq_peripheral
