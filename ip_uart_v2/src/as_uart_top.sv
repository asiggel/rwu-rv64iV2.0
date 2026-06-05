// =============================================================================
// as_uart_top.sv  –  UART Peripheral Top Level  (ip_uart_v2)
// =============================================================================
// Register map (byte offsets from peripheral base, base must be 256-byte aligned):
//   0x00  ID_REG    ro   Peripheral ID (0x00000020)
//   0x08  LCR       rw   [1:0]=databits(00=5..11=8), [3:2]=parity(00=none,01=odd,10=even),
//                        [4]=stop2, [5]=break
//   0x10  CLKDIV    rw   [15:0] baud divisor: f_baud = f_clk / (16 * CLKDIV); 0 rejected
//   0x18  CTRL      rw   [0]=loopback, [1]=tx_flush (auto-clear), [2]=rx_flush (auto-clear)
//   0x20  STATUS    ro   [0]=tx_busy, [1]=rx_busy, [7:4]=sticky error flags (mirrors RIS[6:3])
//   0x28  DATA      rw   write: push TX FIFO; read: pop RX FIFO
//   0x30  FIFOSTAT  ro   [4:0]=tx_level, [5]=tx_empty, [6]=tx_half, [7]=tx_full,
//                        [20:16]=rx_level, [21]=rx_empty, [22]=rx_half, [23]=rx_full
//   0x38  RXTHRES   rw   [4:0] RX interrupt threshold (default FIFO_DEPTH/2)
//   0x40  RIS       ro   [0]=rx_ready, [1]=tx_ready, [2]=rx_timeout,
//                        [3]=frame_err, [4]=parity_err, [5]=overrun_err, [6]=break_det
//   0x48  IMSC      rw   Interrupt Mask Control
//   0x50  MIS       ro   Masked Interrupt Status = RIS & IMSC
//   0x58  ICR       wo   Interrupt Clear: write-1-to-clear corresponding RIS bits
// =============================================================================
`timescale 1ns/1ps

import as_pack::*;

module as_uart_top #(
  parameter int UART_ADDR_WIDTH = 8,
  parameter int UART_DATA_WIDTH = 64,
  parameter int FIFO_DEPTH      = 16
)(
  input  logic                       clk_i,
  input  logic                       rst_i,
  input  logic [UART_ADDR_WIDTH-1:0] wbdAddr_i,
  input  logic [reg_width-1:0]       wbdDat_i,
  output logic [reg_width-1:0]       wbdDat_o,
  input  logic                       wbdWe_i,
  input  logic [wbdSel-1:0]          wbdSel_i,
  input  logic                       wbdStb_i,
  output logic                       wbdAck_o,
  input  logic                       wbdCyc_i,
  output logic                       tx_o,
  input  logic                       rx_i,
  output logic                       uart_irq_o
);

  // ===========================================================================
  // Register offsets and reset values
  // ===========================================================================
  localparam int OFF_ID       =  0;
  localparam int OFF_LCR      =  8;
  localparam int OFF_CLKDIV   = 16;
  localparam int OFF_CTRL     = 24;
  localparam int OFF_STATUS   = 32;
  localparam int OFF_DATA     = 40;
  localparam int OFF_FIFOSTAT = 48;
  localparam int OFF_RXTHRES  = 56;
  localparam int OFF_RIS      = 64;
  localparam int OFF_IMSC     = 72;
  localparam int OFF_MIS      = 80;
  localparam int OFF_ICR      = 88;

  localparam logic [63:0] RST_ID      = 64'h00000000_00000020;
  localparam logic [63:0] RST_LCR     = 64'h00000000_00000003; // 8N1, no break
  localparam logic [63:0] RST_CLKDIV  = 64'h00000000_00000044; // 68 → 115200 baud @125 MHz
  localparam logic [63:0] RST_CTRL    = 64'h00000000_00000000;
  localparam logic [63:0] RST_RXTHRES = 64'(FIFO_DEPTH / 2);
  localparam logic [63:0] RST_IMSC    = 64'h00000000_00000000;
  localparam logic [63:0] RST_RIS     = 64'h00000000_00000000;

  // 4 × worst-case char time (12 bits × 16 sub-clocks = 192 baud16 ticks/char)
  localparam int TIMEOUT_TICKS = 768;

  // ===========================================================================
  // FSM types
  // ===========================================================================
  typedef enum logic [2:0] {
    TX_IDLE_ST, TX_START_ST, TX_DATA_ST,
    TX_PARITY_ST, TX_STOP1_ST, TX_STOP2_ST
  } tx_state_t;

  typedef enum logic [2:0] {
    RX_IDLE_ST, RX_START_ST, RX_DATA_ST,
    RX_PARITY_ST, RX_STOP_ST
  } rx_state_t;

  // ===========================================================================
  // Signal declarations
  // ===========================================================================

  // BPI
  logic [UART_ADDR_WIDTH-1:0] addr_s;
  logic [reg_width-1:0]       data_wr_s;
  logic [reg_width-1:0]       data_rd_s;
  logic                       wr_s, rd_s;

  // Register write / read strobes
  logic wr_lcr_s, wr_clkdiv_s, wr_ctrl_s, wr_data_s;
  logic wr_rxthres_s, wr_imsc_s, wr_icr_s;
  logic rd_data_s;

  // Configuration registers
  logic [reg_width-1:0] id_reg_s;
  logic [reg_width-1:0] lcr_reg_s;
  logic [reg_width-1:0] clkdiv_reg_s;
  logic [reg_width-1:0] ctrl_reg_s;
  logic [reg_width-1:0] rxthres_reg_s;
  logic [reg_width-1:0] imsc_reg_s;

  // Status / interrupt registers (combinatorial or latched)
  logic [reg_width-1:0] status_reg_s;
  logic [reg_width-1:0] fifostat_reg_s;
  logic [reg_width-1:0] ris_reg_s;
  logic [reg_width-1:0] mis_reg_s;

  // LCR / CTRL decode
  logic [2:0] data_bits_count_s; // 5..8
  logic [1:0] parity_s;          // 00=none 01=odd 10=even
  logic       stop2_s;
  logic       break_s;
  logic       loopback_s;
  logic       tx_flush_s, rx_flush_s;

  // Baud generators
  logic [15:0] baud_cnt_r;
  logic        baud16_s;         // shared TX + timeout tick
  logic [15:0] rx_baud_cnt_r;
  logic        rx_baud16_s;      // RX-private, phase-aligned to start-bit edge

  // TX FSM
  tx_state_t   tx_state_s, tx_nextstate_s;
  logic [3:0]  tx_subcnt_r;
  logic [2:0]  tx_bit_cnt_r;
  logic [7:0]  tx_shift_r;
  logic        tx_parity_r;
  logic        tx_bit_done_s;
  logic        tx_data_done_s;
  logic        tx_busy_s;
  logic        tx_rd_s;
  logic        tx_o_s;

  // TX parity precompute
  logic        tx_data_xor_s;
  logic        tx_parity_precomp_s;

  // RX path
  logic [1:0]  rx_sync_r;       // 2-FF metastability synchroniser
  logic        rx_in_s;         // synchronised + loopback mux
  logic        rx_prev_r;
  logic        rx_fall_s;

  // RX FSM
  rx_state_t   rx_state_s, rx_nextstate_s;
  logic [3:0]  rx_subcnt_r;
  logic [2:0]  rx_bit_cnt_r;
  logic [7:0]  rx_shift_r;
  logic        rx_parity_r;
  logic        rx_valid_start_r; // set at start-bit centre if rx_in==0
  logic        rx_stop_ok_r;     // set at stop-bit centre if rx_in==1
  logic        rx_parity_err_r;  // latched parity-error flag
  logic        rx_fall_pending_r; // falling edge latched while in STOP_ST
  logic        rx_center_s;
  logic        rx_bit_done_s;
  logic        rx_data_done_s;
  logic        rx_busy_s;

  // RX events (one-cycle pulses into RIS)
  logic        rx_wr_s;
  logic [7:0]  rx_wr_data_s;
  logic        ev_frame_err_s;
  logic        ev_break_det_s;
  logic        ev_parity_err_s;
  logic        ev_overrun_err_s;

  // TX FIFO
  logic        tx_full_s, tx_empty_s, tx_half_s;
  logic [7:0]  tx_data_rd_s;
  logic [$clog2(FIFO_DEPTH):0] tx_level_s;

  // RX FIFO
  logic        rx_full_s, rx_empty_s, rx_half_s;
  logic [7:0]  rx_data_rd_s;
  logic [$clog2(FIFO_DEPTH):0] rx_level_s;

  // Interrupt level signals and pulses
  logic        rx_ready_s, tx_ready_s, rx_timeout_s;
  logic        rx_ready_d, tx_ready_d, rx_timeout_d;

  // RX timeout counter
  logic [9:0]  rx_timeout_cnt_r;

  // ===========================================================================
  // Assign statements
  // ===========================================================================

  // LCR / CTRL decode
  assign data_bits_count_s = 3'd5 + {1'b0, lcr_reg_s[1:0]};
  assign parity_s           = lcr_reg_s[3:2];
  assign stop2_s            = lcr_reg_s[4];
  assign break_s            = lcr_reg_s[5];
  assign loopback_s         = ctrl_reg_s[0];
  assign tx_flush_s         = wr_ctrl_s && data_wr_s[1];
  assign rx_flush_s         = wr_ctrl_s && data_wr_s[2];

  // Register write/read strobes
  assign wr_lcr_s     = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_LCR));
  assign wr_clkdiv_s  = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_CLKDIV));
  assign wr_ctrl_s    = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_CTRL));
  assign wr_data_s    = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_DATA));
  assign wr_rxthres_s = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_RXTHRES));
  assign wr_imsc_s    = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_IMSC));
  assign wr_icr_s     = wr_s && (addr_s == UART_ADDR_WIDTH'(OFF_ICR));
  assign rd_data_s    = rd_s && (addr_s == UART_ADDR_WIDTH'(OFF_DATA));

  // Baud generators: >= rather than == so that decreasing CLKDIV resets the
  // counter immediately instead of waiting for a 65535-cycle wrap-around.
  assign baud16_s    = (baud_cnt_r    >= 16'(clkdiv_reg_s[15:0]) - 16'd1);
  assign rx_baud16_s = (rx_baud_cnt_r >= 16'(clkdiv_reg_s[15:0]) - 16'd1);

  // TX helper signals
  assign tx_bit_done_s  = baud16_s && (tx_subcnt_r == 4'd15) && (tx_state_s != TX_IDLE_ST);
  assign tx_data_done_s = (tx_bit_cnt_r == (data_bits_count_s - 3'd1));
  assign tx_busy_s      = (tx_state_s != TX_IDLE_ST);
  assign tx_rd_s        = (tx_state_s == TX_IDLE_ST) && !tx_empty_s;

  // TX parity: precomputed from FIFO head before latching into tx_parity_r
  assign tx_data_xor_s = (data_bits_count_s == 3'd5) ? ^tx_data_rd_s[4:0] :
                          (data_bits_count_s == 3'd6) ? ^tx_data_rd_s[5:0] :
                          (data_bits_count_s == 3'd7) ? ^tx_data_rd_s[6:0] :
                                                         ^tx_data_rd_s[7:0];
  assign tx_parity_precomp_s = (parity_s == 2'b10) ?  tx_data_xor_s
                              : (parity_s == 2'b01) ? ~tx_data_xor_s
                              :                        1'b0;

  // RX helper signals
  assign rx_in_s       = loopback_s ? tx_o_s : rx_sync_r[1];
  assign rx_fall_s     = rx_prev_r & ~rx_in_s;
  assign rx_center_s   = rx_baud16_s && (rx_subcnt_r == 4'd7);
  assign rx_bit_done_s = rx_baud16_s && (rx_subcnt_r == 4'd15);
  assign rx_data_done_s = (rx_bit_cnt_r == (data_bits_count_s - 3'd1));
  assign rx_busy_s     = (rx_state_s != RX_IDLE_ST);

  // RX event pulses (asserted for one cycle at end of STOP state)
  assign rx_wr_s          = (rx_state_s == RX_STOP_ST) && rx_bit_done_s;
  assign rx_wr_data_s     = rx_shift_r;
  assign ev_frame_err_s   = rx_wr_s && !rx_stop_ok_r;
  assign ev_break_det_s   = rx_wr_s && !rx_stop_ok_r && (rx_shift_r == 8'h00);
  assign ev_parity_err_s  = rx_wr_s && rx_parity_err_r && (parity_s != 2'b00);
  assign ev_overrun_err_s = rx_wr_s && rx_full_s;

  // Interrupt level signals and rising-edge pulses
  assign rx_ready_s  = (rx_level_s >= rxthres_reg_s[4:0]);
  assign tx_ready_s  = (tx_level_s <  rxthres_reg_s[4:0]);
  assign rx_timeout_s = (rx_timeout_cnt_r >= 10'(TIMEOUT_TICKS)) && !rx_empty_s;

  // Status register: [1:0] live busy flags, [7:4] mirror sticky RIS error bits
  assign status_reg_s = {56'b0,
                          ris_reg_s[6], ris_reg_s[5], ris_reg_s[4], ris_reg_s[3],
                          2'b0, rx_busy_s, tx_busy_s};

  // FIFO status register
  assign fifostat_reg_s = {reg_width{1'b0}}
    | (64'(rx_full_s)  << 23)
    | (64'(rx_half_s)  << 22)
    | (64'(rx_empty_s) << 21)
    | (64'(rx_level_s) << 16)
    | (64'(tx_full_s)  <<  7)
    | (64'(tx_half_s)  <<  6)
    | (64'(tx_empty_s) <<  5)
    | (64'(tx_level_s));

  assign mis_reg_s  = ris_reg_s & imsc_reg_s;
  assign uart_irq_o = |mis_reg_s;
  assign tx_o       = tx_o_s;

  // ===========================================================================
  // always_comb blocks
  // ===========================================================================

  // TX output logic (FSM block 3)
  always_comb begin
    if (break_s)
      tx_o_s = 1'b0;
    else
      case (tx_state_s)
        TX_IDLE_ST, TX_STOP1_ST, TX_STOP2_ST : tx_o_s = 1'b1;
        TX_START_ST                           : tx_o_s = 1'b0;
        TX_DATA_ST                            : tx_o_s = tx_shift_r[0];
        TX_PARITY_ST                          : tx_o_s = tx_parity_r;
        default                               : tx_o_s = 1'b1;
      endcase
  end

  // TX FSM block 2: input logic (nextstate only)
  always_comb begin
    tx_nextstate_s = tx_state_s;
    case (tx_state_s)
      TX_IDLE_ST:   if (!tx_empty_s && !break_s)
                      tx_nextstate_s = TX_START_ST;
      TX_START_ST:  if (tx_bit_done_s)
                      tx_nextstate_s = TX_DATA_ST;
      TX_DATA_ST:   if (tx_bit_done_s && tx_data_done_s)
                      tx_nextstate_s = (parity_s != 2'b00) ? TX_PARITY_ST : TX_STOP1_ST;
      TX_PARITY_ST: if (tx_bit_done_s)
                      tx_nextstate_s = TX_STOP1_ST;
      TX_STOP1_ST:  if (tx_bit_done_s)
                      tx_nextstate_s = stop2_s ? TX_STOP2_ST : TX_IDLE_ST;
      TX_STOP2_ST:  if (tx_bit_done_s)
                      tx_nextstate_s = TX_IDLE_ST;
      default:      tx_nextstate_s = TX_IDLE_ST;
    endcase
  end

  // RX FSM block 2: input logic (nextstate only)
  // rx_fall_pending_r: a falling edge was captured while still in RX_STOP_ST
  // (back-to-back frames); process it as soon as IDLE is reached.
  always_comb begin
    rx_nextstate_s = rx_state_s;
    case (rx_state_s)
      RX_IDLE_ST:   if (rx_fall_s || rx_fall_pending_r)
                      rx_nextstate_s = RX_START_ST;
      RX_START_ST:  if (rx_bit_done_s)
                      rx_nextstate_s = rx_valid_start_r ? RX_DATA_ST : RX_IDLE_ST;
      RX_DATA_ST:   if (rx_bit_done_s && rx_data_done_s)
                      rx_nextstate_s = (parity_s != 2'b00) ? RX_PARITY_ST : RX_STOP_ST;
      RX_PARITY_ST: if (rx_bit_done_s)
                      rx_nextstate_s = RX_STOP_ST;
      RX_STOP_ST:   if (rx_bit_done_s)
                      rx_nextstate_s = RX_IDLE_ST;
      default:      rx_nextstate_s = RX_IDLE_ST;
    endcase
  end

  // Wishbone read multiplexer
  always_comb begin
    case (addr_s)
      UART_ADDR_WIDTH'(OFF_ID)      : data_rd_s = id_reg_s;
      UART_ADDR_WIDTH'(OFF_LCR)     : data_rd_s = lcr_reg_s;
      UART_ADDR_WIDTH'(OFF_CLKDIV)  : data_rd_s = clkdiv_reg_s;
      UART_ADDR_WIDTH'(OFF_CTRL)    : data_rd_s = ctrl_reg_s;
      UART_ADDR_WIDTH'(OFF_STATUS)  : data_rd_s = status_reg_s;
      UART_ADDR_WIDTH'(OFF_DATA)    : data_rd_s = rx_empty_s ? '0 : {56'b0, rx_data_rd_s};
      UART_ADDR_WIDTH'(OFF_FIFOSTAT): data_rd_s = fifostat_reg_s;
      UART_ADDR_WIDTH'(OFF_RXTHRES) : data_rd_s = rxthres_reg_s;
      UART_ADDR_WIDTH'(OFF_RIS)     : data_rd_s = ris_reg_s;
      UART_ADDR_WIDTH'(OFF_IMSC)    : data_rd_s = imsc_reg_s;
      UART_ADDR_WIDTH'(OFF_MIS)     : data_rd_s = mis_reg_s;
      UART_ADDR_WIDTH'(OFF_ICR)     : data_rd_s = '0;
      default                       : data_rd_s = '0;
    endcase
  end

  // ===========================================================================
  // always_ff blocks
  // ===========================================================================

  // Shared baud counter (TX + timeout)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) baud_cnt_r <= '0;
    else       baud_cnt_r <= baud16_s ? '0 : baud_cnt_r + 16'd1;

  // RX baud counter: phase-resets on falling edge in IDLE, or one cycle after
  // a falling edge that was captured as rx_fall_pending_r (back-to-back frames).
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_baud_cnt_r <= '0;
    else if (rx_state_s == RX_IDLE_ST && (rx_fall_s || rx_fall_pending_r))
      rx_baud_cnt_r <= '0;
    else
      rx_baud_cnt_r <= rx_baud16_s ? '0 : rx_baud_cnt_r + 16'd1;

  // RX 2-FF metastability synchroniser (UART-HW-002)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) rx_sync_r <= 2'b11;
    else begin
      rx_sync_r[0] <= rx_i;
      rx_sync_r[1] <= rx_sync_r[0];
    end

  // Previous RX value for falling-edge detection
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) rx_prev_r <= 1'b1;
    else       rx_prev_r <= rx_in_s;

  // TX FSM block 1: delay
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) tx_state_s <= TX_IDLE_ST;
    else       tx_state_s <= tx_nextstate_s;

  // TX baud sub-counter (0..15 baud16_s ticks per bit state)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      tx_subcnt_r <= '0;
    else if (tx_state_s == TX_IDLE_ST)
      tx_subcnt_r <= '0;
    else if (baud16_s)
      tx_subcnt_r <= tx_subcnt_r + 4'd1;

  // TX data bit counter
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      tx_bit_cnt_r <= '0;
    else if (tx_state_s != TX_DATA_ST)
      tx_bit_cnt_r <= '0;
    else if (tx_bit_done_s)
      tx_bit_cnt_r <= tx_bit_cnt_r + 3'd1;

  // TX shift register: load from FIFO head in IDLE, shift right during DATA
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      tx_shift_r <= '0;
    else if (tx_state_s == TX_IDLE_ST && !tx_empty_s)
      tx_shift_r <= tx_data_rd_s;
    else if (tx_bit_done_s && tx_state_s == TX_DATA_ST)
      tx_shift_r <= {1'b0, tx_shift_r[7:1]};

  // TX parity register: precomputed when loading the shift register
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      tx_parity_r <= 1'b0;
    else if (tx_state_s == TX_IDLE_ST && !tx_empty_s)
      tx_parity_r <= tx_parity_precomp_s;

  // RX FSM block 1: delay
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) rx_state_s <= RX_IDLE_ST;
    else       rx_state_s <= rx_nextstate_s;

  // RX baud sub-counter (0..15 rx_baud16_s ticks per bit state)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_subcnt_r <= '0;
    else if (rx_state_s == RX_IDLE_ST)
      rx_subcnt_r <= '0;
    else if (rx_baud16_s)
      rx_subcnt_r <= rx_subcnt_r + 4'd1;

  // RX data bit counter
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_bit_cnt_r <= '0;
    else if (rx_state_s != RX_DATA_ST)
      rx_bit_cnt_r <= '0;
    else if (rx_bit_done_s && !rx_data_done_s)
      rx_bit_cnt_r <= rx_bit_cnt_r + 3'd1;

  // RX shift register: LSB-first, bits shift in from MSB side
  // After N bits: shift_r[N-1]=bit0, ..., shift_r[0]=bit(N-1) → after 8: [0]=b7, [7]=b0
  // Wait — {rx_in_s, rx_shift_r[7:1]}: after bit0: [7]=b0; after bit7: [0]=b0, [7]=b7 ✓
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_shift_r <= '0;
    else if (rx_state_s == RX_IDLE_ST)
      rx_shift_r <= '0;
    else if (rx_state_s == RX_DATA_ST && rx_center_s)
      rx_shift_r <= {rx_in_s, rx_shift_r[7:1]};

  // RX parity accumulator (running XOR of received data bits)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_parity_r <= 1'b0;
    else if (rx_state_s == RX_IDLE_ST)
      rx_parity_r <= 1'b0;
    else if (rx_state_s == RX_DATA_ST && rx_center_s)
      rx_parity_r <= rx_parity_r ^ rx_in_s;

  // Back-to-back frame: latch a falling edge that arrives while still in STOP_ST.
  // Consumed (cleared) when RX re-enters IDLE and uses it to trigger START_ST.
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_fall_pending_r <= 1'b0;
    else if (rx_state_s == RX_IDLE_ST)
      rx_fall_pending_r <= 1'b0;
    else if (rx_state_s == RX_STOP_ST && rx_fall_s)
      rx_fall_pending_r <= 1'b1;

  // Valid start flag: set when start-bit centre sample is 0 (genuine start, not glitch)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_valid_start_r <= 1'b0;
    else if (rx_state_s == RX_IDLE_ST)
      rx_valid_start_r <= 1'b0;
    else if (rx_state_s == RX_START_ST && rx_center_s)
      rx_valid_start_r <= ~rx_in_s;

  // Stop-bit sample (frame error check: 0 = frame error)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_stop_ok_r <= 1'b1;
    else if (rx_state_s == RX_IDLE_ST)
      rx_stop_ok_r <= 1'b1;
    else if (rx_state_s == RX_STOP_ST && rx_center_s)
      rx_stop_ok_r <= rx_in_s;

  // Parity error flag (latched at parity-bit centre)
  // Even parity: XOR(data) ^ rx_in should == 0; error when != 0
  // Odd parity:  XOR(data) ^ rx_in should == 1; error when != 1
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_parity_err_r <= 1'b0;
    else if (rx_state_s == RX_IDLE_ST)
      rx_parity_err_r <= 1'b0;
    else if (rx_state_s == RX_PARITY_ST && rx_center_s)
      rx_parity_err_r <= (parity_s == 2'b10) ?  (rx_parity_r ^ rx_in_s)
                       : (parity_s == 2'b01) ? !(rx_parity_r ^ rx_in_s)
                       :                        1'b0;

  // RX timeout counter: counts baud16_s ticks since last FIFO write
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      rx_timeout_cnt_r <= '0;
    else if (rx_wr_s || rx_empty_s)
      rx_timeout_cnt_r <= '0;
    else if (baud16_s && !rx_timeout_s)
      rx_timeout_cnt_r <= rx_timeout_cnt_r + 10'd1;

  // Interrupt edge-detection delay registers
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) begin
      rx_ready_d   <= 1'b0;
      tx_ready_d   <= 1'b0;
      rx_timeout_d <= 1'b0;
    end else begin
      rx_ready_d   <= rx_ready_s;
      tx_ready_d   <= tx_ready_s;
      rx_timeout_d <= rx_timeout_s;
    end

  // RIS register
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) begin
      ris_reg_s <= RST_RIS;
    end else begin
      if      (wr_icr_s && data_wr_s[0]) ris_reg_s[0] <= 1'b0;
      else if (rx_ready_s && !rx_ready_d) ris_reg_s[0] <= 1'b1;

      if      (wr_icr_s && data_wr_s[1]) ris_reg_s[1] <= 1'b0;
      else if (tx_ready_s && !tx_ready_d) ris_reg_s[1] <= 1'b1;

      if      (wr_icr_s && data_wr_s[2]) ris_reg_s[2] <= 1'b0;
      else if (rx_timeout_s && !rx_timeout_d) ris_reg_s[2] <= 1'b1;

      if      (wr_icr_s && data_wr_s[3]) ris_reg_s[3] <= 1'b0;
      else if (ev_frame_err_s)            ris_reg_s[3] <= 1'b1;

      if      (wr_icr_s && data_wr_s[4]) ris_reg_s[4] <= 1'b0;
      else if (ev_parity_err_s)           ris_reg_s[4] <= 1'b1;

      if      (wr_icr_s && data_wr_s[5]) ris_reg_s[5] <= 1'b0;
      else if (ev_overrun_err_s)          ris_reg_s[5] <= 1'b1;

      if      (wr_icr_s && data_wr_s[6]) ris_reg_s[6] <= 1'b0;
      else if (ev_break_det_s)            ris_reg_s[6] <= 1'b1;

      ris_reg_s[reg_width-1:7] <= '0;
    end

  // Configuration registers
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i) id_reg_s <= RST_ID;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)         lcr_reg_s <= RST_LCR;
    else if (wr_lcr_s) lcr_reg_s <= data_wr_s;

  // CLKDIV: reject writes of 0 (would cause division by zero)
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)
      clkdiv_reg_s <= RST_CLKDIV;
    else if (wr_clkdiv_s && data_wr_s[15:0] != 16'h0000)
      clkdiv_reg_s <= data_wr_s;

  // CTRL: flush bits [2:1] are write-only (auto-clear); only loopback [0] is stored
  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)          ctrl_reg_s <= RST_CTRL;
    else if (wr_ctrl_s) ctrl_reg_s <= data_wr_s & ~64'h6;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)             rxthres_reg_s <= RST_RXTHRES;
    else if (wr_rxthres_s) rxthres_reg_s <= data_wr_s;

  always_ff @(posedge clk_i, posedge rst_i)
    if (rst_i)          imsc_reg_s <= RST_IMSC;
    else if (wr_imsc_s) imsc_reg_s <= data_wr_s;

  // ===========================================================================
  // Module instantiations
  // ===========================================================================

  as_slave_bpi #(UART_ADDR_WIDTH, UART_DATA_WIDTH) u_bpi (
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

  as_fifo #(.DATA_WIDTH(8), .FIFO_DEPTH(FIFO_DEPTH)) u_txfifo (
    .rst_i         (rst_i),
    .clk_i         (clk_i),
    .flush_i       (tx_flush_s),
    .wr_en_i       (wr_data_s && !tx_full_s),
    .data_wr_i     (data_wr_s[7:0]),
    .full_o        (tx_full_s),
    .almost_full_o (),
    .half_full_o   (),
    .rd_en_i       (tx_rd_s),
    .data_rd_o     (tx_data_rd_s),
    .empty_o       (tx_empty_s),
    .almost_empty_o(),
    .half_empty_o  (tx_half_s),
    .level_o       (tx_level_s)
  );

  as_fifo #(.DATA_WIDTH(8), .FIFO_DEPTH(FIFO_DEPTH)) u_rxfifo (
    .rst_i         (rst_i),
    .clk_i         (clk_i),
    .flush_i       (rx_flush_s),
    .wr_en_i       (rx_wr_s && !rx_full_s),
    .data_wr_i     (rx_wr_data_s),
    .full_o        (rx_full_s),
    .almost_full_o (),
    .half_full_o   (rx_half_s),
    .rd_en_i       (rd_data_s && !rx_empty_s),
    .data_rd_o     (rx_data_rd_s),
    .empty_o       (rx_empty_s),
    .almost_empty_o(),
    .half_empty_o  (),
    .level_o       (rx_level_s)
  );

endmodule : as_uart_top
