

// =============================================================================
// asQspiTop.sv  –  QSPI Peripheral Top Level  (v2)
// =============================================================================
// Register map (byte offsets from as_pack.sv + extended):
//   0x00  ID_REG     ro   Peripheral ID
//   0x08  CTRL_REG   rw   [11:4]=qspi_ctrl_t, [3]=start(pulse), [2]=rx_flush, [1]=tx_flush
//   0x10  CMD_REG    rw   [7:0] opcode
//   0x18  ADDR_REG   rw   [31:0] flash address
//   0x20  LEN_REG    rw   [15:0] bytes to transfer
//   0x28  DUMMY_REG  rw   [5:0] dummy cycles
//   0x30  CLKDIV_REG rw   [7:0] SCK divider
//   0x38  TIMEOUT_REG rw  [31:0] timeout counter
//   0x40  ISR        wo   Interrupt Set Register   (w1→set RIS)
//   0x48  RIS        ro   Raw Interrupt Status     [4]=TO,[3]=ERR,[2]=TXHALF,[1]=RXHALF,[0]=DONE
//   0x50  IMSC       rw   Interrupt Mask Control
//   0x58  MIS        ro   Masked Interrupt Status = RIS & IMSC
//   0x60  ICR        wo   Interrupt Clear Register (w1→clear RIS)
//   0x68  RXDATA     ro   Pop from RX FIFO
//   0x70  TXDATA     wo   Push to TX FIFO
//   0x78  FIFOSTAT   ro   [28:24]=rx_level, [20]=rx_full, [19]=rx_half,
//                          [12:8]=tx_level,  [4]=tx_full, [3]=tx_half
//   0x80  XIPMODE    rw   [7:0] XIP mode byte
//   0x88  STATUS     ro   [4]=timeout,[3]=error,[2]=xip_active,[1]=done,[0]=busy
// =============================================================================
`timescale 1ns/1ps

import as_pack::*;

module as_qspi_top #(
  parameter int QSPI_ADDR_WIDTH = 64,
  parameter int QSPI_DATA_WIDTH = 64,
  parameter int FIFO_DEPTH      = 16
)(
  input  logic                       rst_i,
  input  logic                       clk_i,
  // Wishbone slave
  input  logic [QSPI_ADDR_WIDTH-1:0] wbdAddr_i,
  input  logic [reg_width-1:0]       wbdDat_i,
  output logic [reg_width-1:0]       wbdDat_o,
  input  logic                       wbdWe_i,
  input  logic [wbdSel-1:0]          wbdSel_i,
  input  logic                       wbdStb_i,
  output logic                       wbdAck_o,
  input  logic                       wbdCyc_i,
  // SPI
  output logic                       sck_o,
  output logic                       cs_o,
  inout  tri   [3:0]                 data_io,
  // IRQ
  output logic                       qspi_irq_o
);

  // ---------------------------------------------------------------------------
  // Register address offsets (must match as_pack.sv exactly + extensions)
  // ---------------------------------------------------------------------------
  localparam int
    OFF_ID       =   0,   // qspi_id_reg_addr_offs_c      weg damit
    OFF_CTRL     =   8,   // qspi_ctrl_reg_addr_offs_c
    OFF_CMD      =  16,   // qspi_cmd_reg_addr_offs_c
    OFF_ADDR     =  24,   // qspi_addr_reg_addr_offs_c    weg damit
    OFF_LEN      =  32,   // qspi_len_reg_addr_offs_c
    OFF_DUMMY    =  40,   // qspi_dummy_reg_addr_offs_c
    OFF_CLKDIV   =  48,   // qspi_clkdiv_reg_addr_offs_c
    OFF_TIMEOUT  =  56,   // qspi_timeout_reg_addr_offs_c
    OFF_ISR      =  64,   // qspi_isr_reg_addr_offs_c
    OFF_RIS      =  72,   // qspi_ris_reg_addr_offs_c
    OFF_IMSC     =  80,   // qspi_imsc_reg_addr_offs_c
    OFF_MIS      =  88,   // qspi_mis_reg_addr_offs_c
    OFF_ICR      =  96,   // qspi_icr_reg_addr_offs_c
    OFF_RXDATA   = 104,   // qspi_rx_reg_addr_offs_c
    OFF_TXDATA   = 112,   // qspi_tx_reg_addr_offs_c
    OFF_FIFOSTAT = 120,   // qspi_fifost_reg_addr_offs_c
    OFF_XIPMODE  = 128,   // qspi_xip_reg_addr_offs_c
    OFF_STATUS   = 136;   // qspi_stat_reg_addr_offs_c

  // ---------------------------------------------------------------------------
  // BPI: Wishbone ↔ internal bus
  // ---------------------------------------------------------------------------
  logic [QSPI_ADDR_WIDTH-1:0] addr_s;
  logic [reg_width-1:0]       data_wr_s;
  logic [reg_width-1:0]       data_rd_s;
  logic                       wr_s, rd_s;

  as_slave_bpi #(QSPI_ADDR_WIDTH, QSPI_DATA_WIDTH) u_bpi (
    .rst_i          (rst_i),
    .clk_i          (clk_i),
    .addr_o         (addr_s),
    .dat_from_core_i(data_rd_s),
    .dat_to_core_o  (data_wr_s),
    .wr_o           (wr_s),
    .rd_o           (rd_s),
    .wb_s_addr_i    (wbdAddr_i),
    .wb_s_dat_i     (wbdDat_i),
    .wb_s_dat_o     (wbdDat_o),
    .wb_s_we_i      (wbdWe_i),
    .wb_s_sel_i     (wbdSel_i),
    .wb_s_stb_i     (wbdStb_i),
    .wb_s_ack_o     (wbdAck_o),
    .wb_s_cyc_i     (wbdCyc_i)
  );


  // ---------------------------------------------------------------------------
  // Register section
  // ---------------------------------------------------------------------------
  
  // Write/read decode
  wire wr_id       = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_ID)); // not needed
  logic wr_ctrl_s;    //     = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_CTRL));
  logic	wr_cmd_s;     //      = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_CMD));
  logic	wr_addr_s;    //   = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_addr_reg_addr_offs_c));
  logic	wr_len_s;     //      = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_LEN));
  logic	wr_dummy_s;   //    = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_DUMMY));
  logic	wr_clkdiv_s;  //   = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_CLKDIV));
  logic	wr_timeout_s; //  = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_TIMEOUT));
  logic	wr_isr_s;     //      = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_ISR));
  logic	wr_icr_s;     //      = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_ICR));
  logic	wr_imsc_s;    //     = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_IMSC));
  logic	wr_txdata_s;  //   = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_TXDATA));
  logic	wr_xipmode_s; //  = wr_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_XIPMODE));
  logic	rd_rxdata_s;  //   = rd_s && (addr_s == QSPI_ADDR_WIDTH'(OFF_RXDATA));

  assign wr_addr_s    = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_addr_reg_addr_offs_c));
  assign wr_ctrl_s    = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_ctrl_reg_addr_offs_c));
  assign wr_cmd_s     = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_cmd_reg_addr_offs_c));
  assign wr_len_s     = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_len_reg_addr_offs_c));
  assign wr_dummy_s   = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_dummy_reg_addr_offs_c));
  assign wr_clkdiv_s  = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_clkdiv_reg_addr_offs_c));
  assign wr_timeout_s = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_timeout_reg_addr_offs_c));
  assign wr_xipmode_s = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_xip_reg_addr_offs_c));
  assign wr_imsc_s    = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_imsc_reg_addr_offs_c));
  assign wr_isr_s     = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_isr_reg_addr_offs_c));
  assign wr_icr_s     = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_icr_reg_addr_offs_c));
  assign rd_rxdata_s  = rd_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_rx_reg_addr_offs_c));
  assign wr_txdata_s  = wr_s && (addr_s == QSPI_ADDR_WIDTH'(qspi_tx_reg_addr_offs_c));

  // ---------------------------------------------------------------------------
  // ID register: 64 bit, r
  // ---------------------------------------------------------------------------
  logic [reg_width-1:0] id_reg_s;

  // ID is read-only: always returns the reset constant, never changes
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) id_reg_s <= reg_width'(qspi_id_reg_addr_rst_c);
    // no else: register holds its value (= always reset value since never written)

  // ---------------------------------------------------------------------------
  // Configuration registers
  // ---------------------------------------------------------------------------
  logic [reg_width-1:0] ctrl_reg_s;
  logic [reg_width-1:0] cmd_reg_s;
  logic [reg_width-1:0] addr_reg_s;
  logic [reg_width-1:0] len_reg_s;
  logic [reg_width-1:0] dummy_reg_s;
  logic [reg_width-1:0] clkdiv_reg_s;
  logic [reg_width-1:0] timeout_reg_s;
  logic [reg_width-1:0] xipmode_reg_s;
  logic [reg_width-1:0] imsc_reg_s;
  
  // ---------------------------------------------------------------------------
  // QSPI ctrl register: 64 bit, rw
  // - clear start after storing; all bits of data_wr_s will be unchanged, except where 0x0E has one (0000_1110)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) ctrl_reg_s <= qspi_ctrl_reg_addr_rst_c;
    else if (wr_ctrl_s) ctrl_reg_s <= data_wr_s & ~64'h0E;

  // ---------------------------------------------------------------------------
  // QSPI cmd register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) cmd_reg_s <= qspi_cmd_reg_addr_rst_c;
    else if (wr_cmd_s) cmd_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI addr register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) addr_reg_s <= qspi_addr_reg_rst_c;
    else if (wr_addr_s) addr_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI len register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) len_reg_s <= qspi_len_reg_rst_c;
    else if (wr_len_s) len_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI dummy register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) dummy_reg_s <= qspi_dummy_reg_rst_c;
    else if (wr_dummy_s) dummy_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI clkdiv register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) clkdiv_reg_s <= qspi_clkdiv_reg_rst_c;
    else if (wr_clkdiv_s) clkdiv_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI timeout register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) timeout_reg_s <= qspi_timeout_reg_rst_c;
    else if (wr_timeout_s) timeout_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI xipmode register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) xipmode_reg_s <= qspi_xip_reg_rst_c;
    else if (wr_xipmode_s) xipmode_reg_s <= data_wr_s;

  // ---------------------------------------------------------------------------
  // QSPI imsc register: 64 bit, rw
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) imsc_reg_s <= reg_width'(qspi_imsc_reg_rst_c);
    else if (wr_imsc_s) imsc_reg_s <= data_wr_s;
  
  // ---------------------------------------------------------------------------
  // Decodes from registers
  // ---------------------------------------------------------------------------
  // CTRL decode for kernel
  qspi_ctrl_t ctrl_k_s;
  assign ctrl_k_s = qspi_ctrl_t'(ctrl_reg_s[11:4]);

  // start_s: one-cycle pulse to kernel when CTRL[3] written as 1.
  // We register the write enable itself to produce a one-shot.
  logic start_r;
  logic start_s;
  
  always_ff @(posedge clk_i)
    if (rst_i) start_r <= 1'b0;
    else        start_r <= wr_ctrl_s && data_wr_s[3];

  // Pulse: high for exactly 1 cycle on the posedge after the write
  assign start_s = start_r;

  // TX/RX flush: one cycle pulse matching the write cycle
  logic tx_flush_s, rx_flush_s;
  assign tx_flush_s = wr_ctrl_s && data_wr_s[1];
  assign rx_flush_s = wr_ctrl_s && data_wr_s[2];
  

  // ---------------------------------------------------------------------------
  // TX FIFO (with register), bus data will be written directly to FIFO (data_wr_s)
  // ---------------------------------------------------------------------------
  logic        tx_full_s, tx_empty_s, tx_half_s;
  logic [63:0] tx_data_rd_s;
  logic        tx_rd_kernel_s;
  logic [$clog2(FIFO_DEPTH):0] tx_level_s;

  as_fifo #(.DATA_WIDTH(64), .FIFO_DEPTH(FIFO_DEPTH)) u_txfifo (
    .rst_i         (rst_i),
    .clk_i         (clk_i),
    .flush_i       (tx_flush_s),
    .wr_en_i       (wr_txdata_s && !tx_full_s),
    .data_wr_i     (data_wr_s),
    .full_o        (tx_full_s),
    .almost_full_o (),
    .half_full_o   (),
    .rd_en_i       (tx_rd_kernel_s),
    .data_rd_o     (tx_data_rd_s),
    .empty_o       (tx_empty_s),
    .almost_empty_o(),
    .half_empty_o  (tx_half_s),
    .level_o       (tx_level_s)
  );

  // ---------------------------------------------------------------------------
  // RX FIFO (with register); FIFO output will be written on bus
  // ---------------------------------------------------------------------------
  logic        rx_full_s, rx_empty_s, rx_half_s;
  logic [63:0] rx_data_rd_s;
  logic        rx_wr_kernel_s;
  logic [63:0] rx_data_kernel_s;
  logic [$clog2(FIFO_DEPTH):0] rx_level_s;

  // NBA timing fix for rx_shift_r:
  // Cycle N:   rx_wr_kernel_s=1. rx_shift_r NBA pending → rx_data_o has OLD value.
  // Cycle N+1: rx_wr_d1=1.       rx_shift_r NBA settled → rx_data_o has CORRECT value.
  //            rx_data_snap captures the correct value HERE.
  // Cycle N+2: rx_wr_d2=1.       Write correct data_snap into FIFO.
  logic        rx_wr_d1, rx_wr_d2;
  logic [63:0] rx_data_snap;
  always_ff @(posedge clk_i)
    if (rst_i) begin
      rx_wr_d1   <= 0;
      rx_wr_d2   <= 0;
      rx_data_snap <= '0;
    end else begin
      rx_wr_d1     <= rx_wr_kernel_s;
      rx_wr_d2     <= rx_wr_d1;
      // Read rx_data_o when rx_wr_d1=1: rx_shift_r is fully settled
      if (rx_wr_d1) rx_data_snap <= rx_data_kernel_s;
    end

  // rx_pop_r: delay the FIFO read-pointer advance by 1 cycle.
  // This separates "present data on bus" from "pop the entry", so the
  // combinatorial data_rd_o = mem[rd_ptr_r] is stable in the read cycle.
  logic rx_pop_r;
  always_ff @(posedge clk_i)
    if (rst_i) rx_pop_r <= 1'b0;
    else       rx_pop_r <= rd_rxdata_s && !rx_empty_s;

  as_fifo #(.DATA_WIDTH(64), .FIFO_DEPTH(FIFO_DEPTH)) u_rxfifo (
    .rst_i         (rst_i),
    .clk_i         (clk_i),
    .flush_i       (rx_flush_s),
    .wr_en_i       (rx_wr_d2),
    .data_wr_i     (rx_data_snap),
    .full_o        (rx_full_s),
    .almost_full_o (),
    .half_full_o   (rx_half_s),
    .rd_en_i       (rx_pop_r),          // delayed pop: data presented BEFORE pointer advances
    .data_rd_o     (rx_data_rd_s),
    .empty_o       (rx_empty_s),
    .almost_empty_o(),
    .half_empty_o  (),
    .level_o       (rx_level_s)
  );

  // ---------------------------------------------------------------------------
  // QSPI kernel
  // ---------------------------------------------------------------------------
  logic stat_busy_s, stat_done_s, stat_error_s, stat_timeout_s, xip_active_s;

  as_qspi u_qspi (
    .rst_i          (rst_i),
    .clk_i          (clk_i),
    .start_i        (start_s),
    .ctrl_reg_i     (ctrl_k_s),
    .cmd_reg_i      (cmd_reg_s[7:0]),
    .addr_reg_i     (addr_reg_s[31:0]),
    .len_reg_i      (len_reg_s[15:0]),
    .dummy_reg_i    (dummy_reg_s[5:0]),
    .clkdiv_reg_i   (clkdiv_reg_s[7:0]),
    .timeout_reg_i  (timeout_reg_s[31:0]),
    .xip_mode_bits_i(xipmode_reg_s[7:0]),
    .xip_active_o   (xip_active_s),
    .stat_busy_o    (stat_busy_s),
    .stat_done_o    (stat_done_s),
    .stat_error_o   (stat_error_s),
    .stat_timeout_o (stat_timeout_s),
    .tx_empty_i     (tx_empty_s),
    .tx_rd_o        (tx_rd_kernel_s),
    .tx_data_i      (tx_data_rd_s),
    .rx_full_i      (rx_full_s),
    .rx_wr_o        (rx_wr_kernel_s),
    .rx_data_o      (rx_data_kernel_s),
    .sck_o          (sck_o),
    .cs_o           (cs_o),
    .data_io        (data_io)
  );

  // ---------------------------------------------------------------------------
  // Interrupt logic
  // RIS[0]=DONE, [1]=RXHALF, [2]=TXHALF, [3]=ERROR, [4]=TIMEOUT
  //
  // RIS is a LATCH register:
  //   - HW source (rising edge/pulse) SETS the bit
  //   - ICR write (w1) CLEARS the bit
  //   - ISR write (w1) SETS the bit (SW force)
  //   - Without explicit set/clear: bit HOLDS its value
  // ---------------------------------------------------------------------------
  logic [reg_width-1:0] ris_reg_s;
  logic [reg_width-1:0] mis_reg_s;

  // Edge detection for level-based HW sources
  logic stat_done_d, rx_half_d, tx_half_d, stat_error_d, stat_timeout_d;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      stat_done_d    <= 1'b0; 
      rx_half_d      <= 1'b0; 
      tx_half_d      <= 1'b0;
      stat_error_d   <= 1'b0; 
      stat_timeout_d <= 1'b0;
    end else begin
      stat_done_d    <= stat_done_s;
      rx_half_d      <= rx_half_s;
      tx_half_d      <= tx_half_s;
      stat_error_d   <= stat_error_s;
      stat_timeout_d <= stat_timeout_s;
    end
  end

  wire done_pulse    = stat_done_s    & ~stat_done_d;
  wire rxhalf_pulse  = rx_half_s      & ~rx_half_d;
  wire txhalf_pulse  = tx_half_s      & ~tx_half_d;
  wire error_pulse   = stat_error_s   & ~stat_error_d;
  wire timeout_pulse = stat_timeout_s & ~stat_timeout_d;

  // ---------------------------------------------------------------------------
  // QSPI isr register: 64 bit, w
  // - is not an own register, a write changes RIS
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // QSPI icr register: 64 bit, w
  // - is not an own register, a write changes RIS
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // QSPI mis register: 64 bit, r
  // - is not an own register, it is a combination of RIS and IMSC
  // ---------------------------------------------------------------------------
  
  // ---------------------------------------------------------------------------
  // QSPI ris register: 64 bit, rh
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) begin
      ris_reg_s <= qspi_ris_reg_rst_c;
    end else begin
      // bit 0: DONE
      if      (wr_icr_s && data_wr_s[0]) ris_reg_s[0] <= 1'b0;
      else if (wr_isr_s && data_wr_s[0]) ris_reg_s[0] <= 1'b1;
      else if (done_pulse)               ris_reg_s[0] <= 1'b1;
      // else: hold
      // bit 1: RXHALF
      if      (wr_icr_s && data_wr_s[1]) ris_reg_s[1] <= 1'b0;
      else if (wr_isr_s && data_wr_s[1]) ris_reg_s[1] <= 1'b1;
      else if (rxhalf_pulse)             ris_reg_s[1] <= 1'b1;
      // bit 2: TXHALF
      if      (wr_icr_s && data_wr_s[2]) ris_reg_s[2] <= 1'b0;
      else if (wr_isr_s && data_wr_s[2]) ris_reg_s[2] <= 1'b1;
      else if (txhalf_pulse)             ris_reg_s[2] <= 1'b1;
      // bit 3: ERROR
      if      (wr_icr_s && data_wr_s[3]) ris_reg_s[3] <= 1'b0;
      else if (wr_isr_s && data_wr_s[3]) ris_reg_s[3] <= 1'b1;
      else if (error_pulse)              ris_reg_s[3] <= 1'b1;
      // bit 4: TIMEOUT
      if      (wr_icr_s && data_wr_s[4]) ris_reg_s[4] <= 1'b0;
      else if (wr_isr_s && data_wr_s[4]) ris_reg_s[4] <= 1'b1;
      else if (timeout_pulse)            ris_reg_s[4] <= 1'b1;
      // upper bits always 0
      ris_reg_s[reg_width-1:5] <= '0;
    end

  assign mis_reg_s      = ris_reg_s & imsc_reg_s;
  assign qspi_irq_o = |mis_reg_s;

  // ---------------------------------------------------------------------------
  // STATUS and FIFOSTAT (combinatorial); registered from FIFO
  // ---------------------------------------------------------------------------
  logic [reg_width-1:0] status_s, fifostat_s;

  // ---------------------------------------------------------------------------
  // QSPI status register (from kernel)
  // ---------------------------------------------------------------------------
  assign status_s  = {59'b0, stat_timeout_s, stat_error_s,
                      xip_active_s, stat_done_s, stat_busy_s};
  
  // ---------------------------------------------------------------------------
  // QSPI fifostat register
  // ---------------------------------------------------------------------------
  // FIFOSTAT bit layout (non-overlapping):
  //  [4:0]  tx_level  (0..16, 5 bits)
  //  [8]    tx_half   (TX FIFO < half)
  //  [9]    tx_full
  //  [20:16] rx_level (0..16, 5 bits)
  //  [24]   rx_half   (RX FIFO >= half)
  //  [25]   rx_full
  assign fifostat_s = {reg_width{1'b0}}
    | (64'(rx_full_s)  << 25)
    | (64'(rx_half_s)  << 24)
    | (64'(rx_level_s) << 16)
    | (64'(tx_full_s)  <<  9)
    | (64'(tx_half_s)  <<  8)
    | (64'(tx_level_s));

  // ---------------------------------------------------------------------------
  // Read multiplexer
  // ---------------------------------------------------------------------------

  always_comb begin
    case (addr_s)
      QSPI_ADDR_WIDTH'(qspi_id_reg_addr_offs_c)      : data_rd_s = id_reg_s;
      QSPI_ADDR_WIDTH'(qspi_ctrl_reg_addr_offs_c)    : data_rd_s = ctrl_reg_s;
      QSPI_ADDR_WIDTH'(qspi_cmd_reg_addr_offs_c)     : data_rd_s = cmd_reg_s;
      QSPI_ADDR_WIDTH'(qspi_addr_reg_addr_offs_c)    : data_rd_s = addr_reg_s;
      QSPI_ADDR_WIDTH'(qspi_len_reg_addr_offs_c)     : data_rd_s = len_reg_s;
      QSPI_ADDR_WIDTH'(qspi_dummy_reg_addr_offs_c)   : data_rd_s = dummy_reg_s;
      QSPI_ADDR_WIDTH'(qspi_clkdiv_reg_addr_offs_c)  : data_rd_s = clkdiv_reg_s;
      QSPI_ADDR_WIDTH'(qspi_timeout_reg_addr_offs_c) : data_rd_s = timeout_reg_s;
      QSPI_ADDR_WIDTH'(qspi_isr_reg_addr_offs_c)     : data_rd_s = '0;   // write-only
      QSPI_ADDR_WIDTH'(qspi_ris_reg_addr_offs_c)     : data_rd_s = ris_reg_s;
      QSPI_ADDR_WIDTH'(qspi_imsc_reg_addr_offs_c)    : data_rd_s = imsc_reg_s;
      QSPI_ADDR_WIDTH'(qspi_mis_reg_addr_offs_c)     : data_rd_s = mis_reg_s;
      QSPI_ADDR_WIDTH'(qspi_icr_reg_addr_offs_c)     : data_rd_s = '0;   // write-only
      QSPI_ADDR_WIDTH'(qspi_rx_reg_addr_offs_c)      : data_rd_s = rx_empty_s ? '0 : rx_data_rd_s; // rx_data_rd_s is directly taken from FIFO
      QSPI_ADDR_WIDTH'(qspi_tx_reg_addr_offs_c)      : data_rd_s = '0;   // write-only
      QSPI_ADDR_WIDTH'(qspi_fifost_reg_addr_offs_c)  : data_rd_s = fifostat_s;
      QSPI_ADDR_WIDTH'(qspi_xip_reg_addr_offs_c)     : data_rd_s = xipmode_reg_s;
      QSPI_ADDR_WIDTH'(qspi_stat_reg_addr_offs_c)    : data_rd_s = status_s;
      default                                        : data_rd_s = '0;
    endcase
  end

endmodule : as_qspi_top
