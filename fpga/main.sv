// FPGA top level

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module main #(

  // Number of mic pairs
  parameter int M = `ifdef TDM8    4
                    `elsif TDM24  12
                    `endif
  ) (

  // Clocks
  input  logic          REFCLK,
  output logic          CORECLK,

  // MEMS microphone interface
  output logic          SCK,
  output logic          WS,
  input  logic  [1:M]   SD,

  // Raspberry Pi interface
  output logic          PI_SCK,
  output logic          PI_WS,
  output logic          PI_SD,
  input  logic          PI_ALN,
  inout  logic          PI_SDA,
  input  logic          PI_SCL

);

// ------------------------------------------------------------------

logic        clk;      // Core clock
logic        rst;      // Synchronous reset
logic [7:0]  ctrl;     // Control register value
logic [3:0]  mode;     // Operational mode

// Mic interface
logic        m_rise;   // I2S clock output to mics via clock buffer
logic        m_fall;
logic        m_ws_o;   // I2S word select output to mics
logic [1:M]  m_sd_ti;  // Test pattern loopback
logic [1:M]  m_sd_i;   // I2S multi-lane data input from mics

// Pi interface
logic        p_rise;   // I2S clock output to Pi
logic        p_fall;
logic        p_ws_o;   // I2S word select outputs to mics and Pi
logic        p_sd_o;   // I2S TDM data output to Pi
logic        p_aln_i;  // Aligmnent control signal
logic        p_sda_i;  // I2C data input
logic        p_sda_o;  // I2C data output (open drain)
logic        p_scl_i;  // I2C clock input

// ------------------------------------------------------------------

ioports #(.M(M)) ioports (.*);  // Input/output Ports
clkgen  #(.M(M)) clkgen  (.*);  // Clock Generator
tdm     #(.M(M)) tdm     (.*);  // TDM Aggregator
tstgen  #(.M(M)) tstgen  (.*);  // Test Pattern Generator
i2c              i2c     (.*);  // Mini I2C client

assign CORECLK = clk;     // Constraint hack and test point

// ------------------------------------------------------------------

endmodule
