// I2S TDM aggregator
// FPGA top level

// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module main #(

  // Number of mic pairs
  parameter int M = `ifdef TDM8    4
                    `elsif TDM24  12
                    `endif
  ) (

  // Clocks
  input  logic         REFCLK,    // 12MHz reference clock
  output logic         CORECLK,   // Core clock test output & constraint hack

  // Upstream interface with MEMS microphones
  // Note: FPGA is I2S clock producer and data receiver
  output logic         MIC_SCK,   // I2S clock to mics via clock buffer
  output logic         MIC_WS,    // I2S word select to mics
  input  logic  [1:M]  MIC_SD,    // I2S data from mics

  // Downstream interface with Raspberry Pi 5
  // Note: FPGA is I2S clock producer and data transmitter
  output logic         PI_SCK,    // I2S clock to Pi
  output logic         PI_WS,     // I2S word select to Pi
  output logic         PI_SD,     // I2S data to Pi (TDM or Mux)
  input  logic         PI_ALN,    // Alignment control GPIO from Pi
  inout  logic         PI_SDA,    // I2C data to/from Pi
  input  logic         PI_SCL,    // I2C clock from Pi

  // Mic external loopback (test patterns)
  input  logic         MLB_SCK,   // I2S clock to mics (loopback input)
  input  logic         MLB_WS,    // I2S word select to mics (loopback input)
  output logic  [1:M]  MLB_SD,    // I2S data from mics (loopback output)

  // FPGA board components (debug)
  input  logic  [3:0]  PB,        // Push-buttons, active low
  output logic  [3:0]  LED_R,     // LED Matrix rows, active low
  output logic  [7:0]  LED_C      // LED Matrix columns, active low

);

logic       clk;       // Core clock
logic       rst;       // Synchronous reset
logic [7:0] ctrl;      // Control register value (from I2C target)

// Mic I2S interface
logic       m_rise;    // Clock enable pulse, rising edge
logic       m_fall;    // Clock enable pulse, falling edge
logic       m_sck_li;  // Clock loopback input
logic       m_ws_o;    // Word select output to mics
logic       m_ws_li;   // Word select loopback input
logic [1:M] m_sd_i;    // Data input from mics
logic [1:M] m_sd_lo;   // Data loopback output

logic       m_aln_li;  // Alignment control loopback input

// Pi I2S interface
logic       p_rise;    // Clock enable pulse, rising edge
logic       p_fall;    // Clock enable pulse, falling edge
logic       p_ws_o;    // Word select output to Pi
logic       p_sd_o;    // Data output to Pi

logic       p_aln_i;   // Aligmnent control signal

logic       p_sda_i;   // I2C data input
logic       p_sda_o;   // I2C data output (open drain)
logic       p_scl_i;   // I2C clock input

ioports #(.M(M)) ioports (.*);  // Logic for Input/Output Ports
clkgen  #(.M(M)) clkgen  (.*);  // Clock Generator
tdm     #(.M(M)) tdm     (.*);  // TDM Aggregator
tstgen  #(.M(M)) tstgen  (.*);  // Test Pattern Generator
i2c              i2c     (.*);  // Mini I2C Client

assign CORECLK = clk;  // Constraint hack and test point

// Control Register value on first row of LED Matrix
assign LED_R = ~(4'b0001);
assign LED_C = ~(ctrl);

// ------------------------------------------------------------------

endmodule
