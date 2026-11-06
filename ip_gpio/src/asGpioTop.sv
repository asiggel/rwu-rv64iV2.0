
// asGpioTop.sv
`timescale 1ns/1ps

import as_pack::*;

//-----------------------------------------------
// Wishbone slave: GPIO
//-----------------------------------------------
module as_gpio_top #( parameter gpioaddr_width = 64,
                      parameter	gpiodata_width = 64 )
                   ( input  logic                  rst_i,
                     input  logic                  clk_i,
                     // wishbone side
                     input  logic [gpioaddr_width-1:0] wbdAddr_i, // 7 Bit (more for internal register)
                     input  logic [reg_width-1:0]      wbdDat_i,  // 64 Bit
                     output logic [reg_width-1:0]      wbdDat_o,  // internal register
                     input  logic                      wbdWe_i,
                     input  logic [wbdSel-1:0]         wbdSel_i, // which byte is valid
                     input  logic                      wbdStb_i, // valid cycle
                     output logic                      wbdAck_o, // normal transaction
                     input  logic                      wbdCyc_i, // high for complete bus cycle
                     //output logic [nr_gpios-1:0]       gpio_irq_o, // GPIO IRQ; input changed
                     output logic        gpio_irq_o, // GPIO IRQ; input changed
                     // I/O
                     inout  tri   [nr_gpios-1:0]       gpio_io,    // to Pin
                     output logic                      cs_o       // to Pin
                   );

  // address, data, enable
  logic [gpioaddr_width-1:0] addr_s;
  logic [reg_width-1:0]      data_s;    // data from bus/BPI to kernel
  logic [nr_gpios-1:0]       dataok_s;  // data from kernel to BPI
  logic [reg_width-1:0]      dataob_s;  // data from BPI to bus
  logic                      en_s;

  // IRQ
  logic [nr_gpios-1:0]	     irq_s;        // IRQs from kernel
  logic [reg_width-1:0]      irq_dataob_s; // read data of the IRQ registers

  // registers
  logic [reg_width-1:0]      id_reg_s;      // GPIO peripheral ID-register;                    address=00 (0x00)
  logic [reg_width-1:0]      dir_reg_s;     // GPIO direction register;                        address=08 (0x08)
  logic [reg_width-1:0]      data_reg_s;    // GPIO data register;                             address=16 (0x10)
  // IRQSS 0x18, IRQSM 0x20, IRQSC 0x28, ISR 0x30, RIS 0x38, IMSC 0x40, MIS 0x48, ICR 0x50: as_irq_peripheral
  
  //--------------------------------------------
  // Slave BPI
  //--------------------------------------------
  as_slave_bpi #(gpioaddr_width, gpiodata_width) 
                            sGpioBpi(.rst_i(rst_i),
                                     .clk_i(clk_i),
                                     .addr_o(addr_s),            // address from BPI; for kernel usage
                                     .dat_from_core_i(dataob_s), // data from kernel; should be mapped onto the wb-bus
                                     .dat_to_core_o(data_s),     // data to kernel; for kernel usage
                                     .wr_o(en_s),                // signal to kernel; for kernel usage
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
  // Peripheral kernel
  //--------------------------------------------
  as_gpio  mygpio (.rst_i(rst_i),
                   .clk_i(clk_i),
                   .direction_i(dir_reg_s[nr_gpios-1:0]),
                   .addr_i(addr_s),
                   .data_i(data_reg_s[nr_gpios-1:0]),
                   .data_o(dataok_s),
		   .irq_o(irq_s),
                   .en_i(en_s),
                   .gpio_io(gpio_io),
                   .cs_o(cs_o)
                  );

  //--------------------------------------------
  // SRB: IRQ & DMA
  //--------------------------------------------
  as_irq_peripheral #(.addr_width(gpioaddr_width),
                      .data_width(reg_width),
                      .nr_other_irqs(1),
                      .nr_same_irqs(nr_gpios),
                      .irqs_yes_no(1),
                      .reg_irqsm_rst(gpio_irqsm_reg_rst_c),
                      .reg_imsc_rst(gpio_imsc_reg_rst_c),
                      .addr_offs_irqss(gpio_irqss_reg_addr_offs_c),
                      .addr_offs_irqsc(gpio_irqsc_reg_addr_offs_c),
                      .addr_offs_irqsm(gpio_irqsm_reg_addr_offs_c),
                      .addr_offs_imsc(gpio_imsc_reg_addr_offs_c),
                      .addr_offs_ris(gpio_ris_reg_addr_offs_c),
                      .addr_offs_isr(gpio_isr_reg_addr_offs_c),
                      .addr_offs_icr(gpio_icr_reg_addr_offs_c),
                      .addr_offs_mis(gpio_mis_reg_addr_offs_c)
                     )
                     gpioIrq (.rst_i(rst_i),
                              .clk_i(clk_i),
                              .en_i(en_s),
                              .irq_other_i(1'b0),
                              .irq_same_i(irq_s),
                              .addr_i(addr_s),
                              .data_i(data_s),
                              .data_o(irq_dataob_s),
                              .ris_o(),
                              .irq_o(gpio_irq_o)
                             );
  
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
      id_reg_s        <= gpio_id_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == gpio_id_reg_addr_offs_c[gpioaddr_width-1:0]) )
        id_reg_s      <= data_s;
  end

  // GPIO direction register: 64 bit, rw
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      dir_reg_s <= gpio_direction_reg_addr_rst_c;
    else
      if ( (en_s == 1) & (addr_s == gpio_direction_reg_addr_offs_c[gpioaddr_width-1:0]) )
        dir_reg_s <= data_s;
  end

  // GPIO data register: 64 bit, rw
  // ... first 8 bit of the register; muxed input: either gpio_in or data from bus
  genvar i;
  generate
    for (i=0; i < nr_gpios; i++)
    begin
      always_ff @(posedge clk_i, posedge rst_i)
      begin
        if(rst_i == 1)
          data_reg_s[i] <= gpio_data_reg_addr_rst_c[i];
        else
          if (dir_reg_s[i])
            data_reg_s[i] <= dataok_s[i];  // pad to register
          else
            if ( (en_s == 1) & (addr_s == gpio_data_reg_addr_offs_c[gpioaddr_width-1:0]) )
              data_reg_s[i] <= data_s[i];  // bus to register
      end
    end
  endgenerate

  // ... remaining bits of the data register
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      data_reg_s[reg_width-1:nr_gpios] <= gpio_data_reg_addr_rst_c[reg_width-1:nr_gpios];
    else
      if ( (en_s == 1) & (addr_s == gpio_data_reg_addr_offs_c[gpioaddr_width-1:0]) )
	data_reg_s[reg_width-1:nr_gpios] <= data_s[reg_width-1:nr_gpios];
  end
  
  // read internal (BPI) register or data from core
  always_comb
  begin
    case(addr_s)
      gpio_id_reg_addr_offs_c[gpioaddr_width-1:0]        : dataob_s = id_reg_s;
      gpio_direction_reg_addr_offs_c[gpioaddr_width-1:0] : dataob_s = dir_reg_s;
      gpio_data_reg_addr_offs_c[gpioaddr_width-1:0]      : dataob_s = data_reg_s;
      default                                            : dataob_s = irq_dataob_s;
    endcase
  end
  
  //--------------------------------------------
  // Clock
  //--------------------------------------------

  //--------------------------------------------
  // Sync
  //--------------------------------------------

  //--------------------------------------------
  // FIFO
  //--------------------------------------------
endmodule : as_gpio_top

