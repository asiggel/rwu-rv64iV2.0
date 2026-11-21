
// asGpio.sv
`timescale 1ns/1ps

import as_pack::*;

module as_gpio ( input  logic                       rst_i,
                 input  logic                       clk_i,
                 // Signal exchange with the BPI
                 input  logic [nr_gpios-1:0]        direction_i, // direction of the GPIO
                 input  logic [gpio_addr_width-1:0] addr_i,      // from BPI/WB-Bus
                 input  logic [nr_gpios-1:0]        data_i,      // GPIO outputs; from SFR data register
                 output logic [nr_gpios-1:0]        data_o,      // GPIO inputs; from pad to SFR data register
                 output logic [nr_gpios-1:0]        irq_o,       // IRQs; to BPI-SRB
                 input  logic                       en_i,        // Chip select, derived from WB enable
                 // Chip I/Os: the tri-state driver is in the pad ring
                 output logic [nr_gpios-1:0]        gpio_o,    // to pad: output value
                 output logic [nr_gpios-1:0]        gpio_oe_o, // to pad: output enable, active high
                 input  logic [nr_gpios-1:0]        gpio_i,    // from pad: input value
                 output logic                       cs_o       // to Pin   
                );
  
  logic [nr_gpios-1:0]  gpio_out_s;
  logic [nr_gpios-1:0]  gpio_in_s;

  logic [nr_gpios-1:0][1:0] shift_reg_s;
  logic	[nr_gpios-1:0]      irq_pulse_s;

  //--------------------------------------------
  // resolution function: direction = 0: output
  //                      direction = 1: input
  //--------------------------------------------
  assign gpio_out_s = data_i;
  
  assign gpio_o     = gpio_out_s;
  assign gpio_oe_o  = ~direction_i;
  // An output pin reads back as 0, as with the former in-core tri-state.
  assign gpio_in_s  = direction_i & gpio_i;

  assign data_o = gpio_in_s;
  
  //--------------------------------------------
  // delay/register cs_s
  //--------------------------------------------
  always_ff @(posedge clk_i, posedge rst_i)
  begin
    if(rst_i == 1)
      cs_o          <= 0;
    else
      if ( (en_i == 1) & (addr_i == gpio_data_reg_addr_offs_c[gpio_addr_width-1:0]) )
        cs_o        <= en_i;
      else
        cs_o        <= 0;
  end

  //--------------------------------------------
  // IRQ generation: signal change on input
  //--------------------------------------------
  // Shift register
  genvar k;
  generate
    for (k=0; k < nr_gpios; k++)
    begin
      always_ff @(posedge clk_i, posedge rst_i)
      begin
        if(rst_i == 1)
        begin
          shift_reg_s[k][0] <= 0;
          shift_reg_s[k][1] <= 0;
        end
        else
	begin
	  if (direction_i[k] == 1)
	  begin
            shift_reg_s[k][0] <= gpio_in_s[k];
            shift_reg_s[k][1] <= shift_reg_s[k][0];
	  end
	end
      end
    end // for (k=0; k < nr_gpios; k++)
  endgenerate

  // Edge detector
  genvar l;
  generate
    for (l=0; l < nr_gpios; l++)
      assign irq_pulse_s[l] =  shift_reg_s[l][0] ^ shift_reg_s[l][1];
  endgenerate

  // To IRQ Register
  assign irq_o = irq_pulse_s;
  
endmodule : as_gpio

