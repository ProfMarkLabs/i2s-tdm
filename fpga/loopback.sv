// ********************************************************
// LOOPBACK build only - DO NOT USE for student projects
// ********************************************************

// FPGA top level (LOOPBACK)

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module loopback #(

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
  input  logic          PI_SCL,

  // Loopback signals (internal generator and checker)
  output logic  [1:M]   MSD,
  input  logic          MSCK,
  input  logic          MWS,
  input  logic          PSCK,
  input  logic          PWS,
  input  logic          PSD,
  output logic          PALN

);

// ------------------------------------------------------------------

logic        clk;      // Core clock
logic        rst;      // Synchronous reset
logic [7:0]  ctrl;     // Operational mode

// Mic interface
logic        m_rise;   // I2S clock output to mics via clock buffer
logic        m_fall;
logic        m_ws_o;   // I2S word select output to mics
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

io_ring #(.M(M)) io_ring (.*);  // Input/output logic
clkgen  #(.M(M)) clkgen  (.*);  // Clock Generator
tdm     #(.M(M)) tdm     (.*);  // TDM Aggregator

// MEMS microphones (LOOPBACK)
// I2S clock consumer, data output
logic [1:M] MSDL, MSDR;
generate
for (genvar i = 1; i <= M; i++) begin : mic
  mic_emu #(.ID(i), .LR(0)) L (.SCK(MSCK), .WS(MWS), .SD(MSDL[i]));
  mic_emu #(.ID(i), .LR(1)) R (.SCK(MSCK), .WS(MWS), .SD(MSDR[i]));
end : mic
endgenerate
assign MSD = MSDL | MSDR; 

// Raspberry Pi (LOOPBACK)
// I2S clock consumer, data input
pi_emu  #(.M(M)) pi_emu  (.SCK(PSCK), .WS(PWS), .SD(PSD));

assign p_sda_o =  1;   // Disable I2C data output (LOOPBACK)
assign ctrl    = '0;   // Control register not required (LOOPBACK)
assign PALN    =  0;   // Alignment not required (LOOPBACK)

assign CORECLK = clk;  // Constraint hack and test point

// ------------------------------------------------------------------

endmodule
