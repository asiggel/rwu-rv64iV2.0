
// asQspiTop.sv
`timescale 1ns/1ps

import as_pack::*;

//-----------------------------------------------
// Wishbone slave: QSPI
//-----------------------------------------------
module as_qspi_top #( parameter qspiaddr_width = 64,
                      parameter	qspidata_width = 64 )
                   ( input  logic                      rst_i,
                     input  logic                      clk_i,
                     // wishbone side
                     input  logic [gpioaddr_width-1:0] wbdAddr_i, // Address
                     input  logic [reg_width-1:0]      wbdDat_i,  // Data in
                     output logic [reg_width-1:0]      wbdDat_o,  // Data out
                     input  logic                      wbdWe_i,   // Write enable
                     input  logic [wbdSel-1:0]         wbdSel_i, // which byte is valid
                     input  logic                      wbdStb_i, // valid cycle
                     output logic                      wbdAck_o, // normal transaction
                     input  logic                      wbdCyc_i, // high for complete bus cycle
                     // SPI
                     output logic sck_o,         // SPI clock
                     output logic cs_o,          // Chip select (one or more?)
                     inout  tri   [3:0] data_io, // Data
                     // CPU
                     output logic qspi_irq_s     // IRQ
                   );

  // address, data, enable
  logic [gpioaddr_width-1:0] addr_s;
  logic [reg_width-1:0]      data_s;    // data from bus/BPI to kernel
  logic [nr_gpios-1:0]       dataok_s;  // data from kernel to BPI
  logic [reg_width-1:0]      dataob_s;  // data from BPI to bus
  logic                      en_s, rd_s;

  // IRQ
  logic [nr_gpios-1:0]	     irq_s;        // IRQs from kernel
  logic			     irq_comb_s;   // OR of all IRQs
  logic			     irqsc_comb_s; // OR of all irqsc
  logic			     irqsm_comb_s; // OR of all irqsm, mask
  logic			     irq_mis_s;

  // registers
  logic [reg_width-1:0]      id_reg_s;      // GPIO peripheral ID-register;                    address=00 (0x00)
  logic [reg_width-1:0]      dir_reg_s;     // GPIO direction register;                        address=08 (0x08)
  logic [reg_width-1:0]      data_reg_s;    // GPIO data register;                             address=16 (0x10)
  logic [reg_width-1:0]      irqss_reg_s;   // GPIO Interrupt Request Source Status Register;  address=24 (0x18)
  logic [reg_width-1:0]      irqsc_reg_s;   // GPIO Interrupt Request Source Clear Register;   address=40 (0x28)
  logic [reg_width-1:0]      irqsm_reg_s;   // GPIO Interrupt Request Source Mask Register;    address=32 (0x20)
  logic [reg_width-1:0]      isr_reg_s;     // GPIO Interrupt Set Register;                    address=48 (0x30)
  logic [reg_width-1:0]      ris_reg_s;     // GPIO Raw Interrupt Status Register;             address=56 (0x38)
  logic [reg_width-1:0]      imsc_reg_s;    // GPIO Interrupt Mask Control Register;           address=64 (0x40)
  logic [reg_width-1:0]      mis_reg_s;     // GPIO Masked Interrupt Status Register;          address=72 (0x48)
  
  //--------------------------------------------
  // Slave BPI
  //--------------------------------------------
  as_slave_bpi #(gpioaddr_width, gpiodata_width) 
                            sQspiBpi(.rst_i(rst_i),
                                     .clk_i(clk_i),
                                     .addr_o(addr_s),            // address from BPI; for kernel usage
                                     .dat_from_core_i(dataob_s), // data from kernel; should be mapped onto the wb-bus
                                     .dat_to_core_o(data_s),     // data to kernel; for kernel usage
                                     .wr_o(en_s),                // signal to kernel; for kernel usage
                                     .rd_o(rd_s),
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
  // Peripheral kernel
  //--------------------------------------------
  // - FSM: Controls the flow (command -> address -> dummy cycles -> data)
  // - FIFO: optimizes the data throughput, minimizes the CPU wait times
  // - RX FIFO
  // - TX FIFO
  // - Threshold-IRQ (watermarks)
  // - Blocking vs Nonblocking Zugriff
  // -> registers
  // - QSPI_TXDATA  (write pushes into FIFO)
  // - QSPI_RXDATA  (read pops from FIFO)
  // - QSPI_FIFOSTAT (levels)
  //
  // - QSPI core: generates SCK, CS, IO[3:0]
  // - Baud-rate generator: adjustable clock divider for flexible SPI speeds (up to 100 MHz ++)
  // - XIP (execute in place) - CPU fetch -> QSPI -> Cache -> CPU, own read path, own arbitration against normal QSPI, prefetch, caching
  // - Modi: 1 bit, 2 bit quad; double data rate (?)
  // - konfigurable number of dummy-cycles
  // Wishbone/BPI
  //     |
  // Register & IRQ & DMA (SRB)
  //     |
  // QSPI kernel
  //     |
  // SPI PHY (SCK/CS/IO)
  // - New register:
  //         CMD	Opcode (z.B. 0x03, 0x0B, 0xEB …)
  //         ADDR	Flash-Adresse
  //         LEN	Anzahl Bytes
  //         CTRL	Start, Mode, Quad, DDR, XIP
  //         STATUS	Busy, FIFO level, done
  //         DUMMY	Dummy cycles
  //
  // Clear semantic signal needed:
  // - start_s = (en_s && addr_s == QSPI_CTRL && data_s[0]);
  // In kernel:
  // - if(start_s && !busy)
  // -   fsm_state <= CMD_PHASE;
  // Without this: again event-driven instead of state-driven
  //
  // IRQSx registers not needed. Just (all in RIS, but then a ISC (clear) must be implemented):
  // - Bit	Bedeutung
  // - 0	Transfer done
  // - 1	FIFO half
  // - 2	FIFO empty
  // - 3	Error
  // - 4	Timeout
  //
  // (A) Busy-Flag
  // - status_reg[0] = busy;
  // (B) Error-Latches
  // - illegal command
  // - fifo overflow
  // - timeout
  // - xip conflict
  
  as_qspi  myqspi (.rst_i(rst_i),
                   .clk_i(clk_i),
                   .....
                  );
  
  //--------------------------------------------
  // IRQ registers
  // r: readable by CPU
  // w: writable by CPU
  // h: writable by HW only
  // X0: read returns a 0
  //--------------------------------------------
  /* A pulse on an interrupt request <xyz>_IRQ sets the corresponding interrupt status bit in
the Raw Interrupt Status Register RIS. The interrupt status bits can be set with the
Interrupt Set Register ISR or can be cleared with the Interrupt Clear Register ICR.
The Interrupt Mask Control Register IMSC enables or disables the level sensitive
interrupts to the ICU. The Masked Interrupt Status Register MIS gives the current
masked status value of the corresponding interrupt.
If an IMSC bit is disabled while its interrupt is active, then the interrupt for the ICU will be
removed, but only until this IMSC bit is enabled again, unless the interrupt has been
cleared in the mean time.
If the IMSC bit is not enabled when an interrupt source becomes active, then the interrupt
bit will only be set in the RIS register. If the corresponding IMSC bit is later enabled, the
interrupt will consequently become active in the MIS register.
Before enabling an interrupt in the MIS bit, it is good practice to always first clear the
corresponding interrupt in the RIS via ICR.*/

  // RIS (Raw Interrupt Status Register): 64 bit, r,h
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      ris_reg_s                <= qspi_ris_reg_rst_c;
    else
    begin
      ris_reg_s[0]             <= irq01_from_kernel; // replace by real one
      ris_reg_s[1]             <= irq02_from_kernel; // replace by real one
      ris_reg_s[reg_width-1:2] <= 0;
    end
  end // always_ff @ (posedge clk_i, posedge rst_i)

  // MUX like structure needed: on write to ICR -> RIS will be cleared
  //                            on write to ISR -> RIS will be set

  // ISR (Interrupt Set Register): 64 bit, X0,w
  /*The Interrupt Set Register ISR is a write-only register. On a write of 1, the corresponding
interrupt is set. A write of 0 has no effect.*/
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      isr_reg_s        <= qspi_isr_reg_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_isr_reg_addr_offs_c) )
        isr_reg_s      <= data_s;
  end

  // ICR (Interrupt Clear Register): 64 bit, X0,w
  /*The Interrupt Clear Register ICR is a write-only register. On a write of 1, the
corresponding interrupt is cleared. A write of 0 has no effect.*/
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      icr_reg_s        <= qspi_icr_reg_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_icr_reg_addr_offs_c) )
        icr_reg_s      <= data_s;
  end

  // IMSC (Interrupt Mask Control Register): 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      imsc_reg_s        <= qspi_imsc_reg_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_imsc_reg_addr_offs_c) )
        imsc_reg_s      <= data_s;
  end

  // MIS (Masked Interrupt Status Register): 64 bit, rh
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      mis_reg_s        <= qspi_mis_reg_rst_c;
    else
      mis_reg_s      <= imsc_reg_s & ris_reg_s;
  end

  // QSPI IRQ
  //assign irq_mis_s  = imsc_reg_s[0] & ris_reg_s[0];
  //assign gpio_irq_o = irq_mis_s; // rename!
  
  //--------------------------------------------
  // SFR: all other registers
  //      in:  rst_i
  //      in:  clk_i
  //      in:  addr_s
  //      in:  data_s
  //      in:  dataok_s
  //      in:  en_s
  //      out: dataob_s
  //--------------------------------------------
  // Peripheral ID: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      id_reg_s        <= qspi_id_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_id_reg_addr_offs_c) )
        id_reg_s      <= data_s;
  end

  // QSPI ctrl register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      ctrl_reg_s <= qspi_ctrl_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_ctrl_reg_addr_offs_c) )
        ctrl_reg_s <= data_s;
  end

  // QSPI cmd register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      cmd_reg_s <= qspi_cmd_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_cmd_reg_addr_offs_c) )
        cmd_reg_s <= data_s;
  end

  // QSPI addr register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      addr_reg_s <= qspi_addr_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_addr_reg_addr_offs_c) )
        addr_reg_s <= data_s;
  end

  // QSPI len register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      len_reg_s <= qspi_len_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_len_reg_addr_offs_c) )
        len_reg_s <= data_s;
  end

  // QSPI dummy register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      dummy_reg_s <= qspi_dummy_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_dummy_reg_addr_offs_c) )
        dummy_reg_s <= data_s;
  end

  // QSPI clkdiv register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      clkdiv_reg_s <= qspi_clkdiv_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_clkdiv_reg_addr_offs_c) )
        clkdiv_reg_s <= data_s;
  end

  // QSPI timeout register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      timeout_reg_s <= qspi_timeout_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_timeout_reg_addr_offs_c) )
        timeout_reg_s <= data_s;
  end

  // QSPI rx register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      rx_reg_s <= qspi_rx_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_rx_reg_addr_offs_c) )
        rx_reg_s <= data_s;
  end

  // QSPI tx register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      tx_reg_s <= qspi_tx_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == qspi_tx_reg_addr_offs_c) )
        tx_reg_s <= data_s;
  end

  // read internal (BPI) register or data from core // rename!
  always_comb
  begin
    case(addr_s)
      gpio_id_reg_addr_offs_c        : dataob_s = id_reg_s;
      gpio_ctrl_reg_addr_offs_c      : dataob_s = ctrl_reg_s;
      gpio_cmd_reg_addr_offs_c       : dataob_s = cmd_reg_s;
      gpio_addr_reg_addr_offs_c      : dataob_s = addr_reg_s;
      gpio_len_reg_addr_offs_c       : dataob_s = len_reg_s;
      gpio_dummy_reg_addr_offs_c     : dataob_s = dummy_reg_s;
      gpio_clkdiv_reg_addr_offs_c    : dataob_s = clkdiv_reg_s;
      gpio_timeout_reg_addr_offs_c   : dataob_s = timeout_reg_s;
      gpio_rx_reg_addr_offs_c        : dataob_s = rx_reg_s;
      gpio_tx_reg_addr_offs_c        : dataob_s = tx_reg_s; // What happens on read? Possible?
      gpio_imsc_reg_addr_offs_c      : dataob_s = imsc_reg_s;
      gpio_icr_reg_addr_offs_c       : dataob_s = 0;
      gpio_isr_reg_addr_offs_c       : dataob_s = 0;
      gpio_mis_reg_addr_offs_c       : dataob_s = mis_reg_s;
      gpio_ris_reg_addr_offs_c       : dataob_s = ris_reg_s;
      default                        : dataob_s = 0; // should not happen
    endcase
  end
  
  //--------------------------------------------
  // Clock
  //--------------------------------------------
  // Needed here or generated in CGU?

  //--------------------------------------------
  // Sync
  //--------------------------------------------
  // Synchronizers are needed

  //--------------------------------------------
  // FIFO
  //--------------------------------------------
  // A FIFO is needed
  // TX FIFO: decouples CPU write timing from QSPI shift timing
  // RX FIFO: allows burst reads without CPU stall

  as_fifo #(....) 
          rxfifo(...);
  
  as_fifo #(....) 
          txfifo(...);
  
endmodule : as_qspi_top

