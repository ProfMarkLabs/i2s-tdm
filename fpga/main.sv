// I2S TDM aggregator
// Design top level
// ------------------------------------------------------------------
// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD
// ------------------------------------------------------------------
// FEATURES
//
//  * Aggregates multiple I2S stereo PCM intefaces into a single TDM stream
//  * Architecture: store-and-forward, gapless (no speed-up)
//  * Offline in-band frame alignment, triggered by an external signal
//  * Fully synchronous design:
//      - I2S clock producer for both interfaces
//      - Common core clock, running at 2x the faster interface
//      - Clock enable pulses (clock-as-data to minimize output skew)
//  * All outputs combinational (registered in ioports module)
//
//   Clock rate ratio:         MIC_SCK (1) :  clk (2M) : PI_CLK (M)
//   e.g. M=4 PCM=2*32 @ 48kHz    3.072MHz : 24.576MHz : 12.288MHz
//
// EXAMPLE APPLICATION
//
//        M lanes x 2-channel PCM                1 lane x 2M-channel TDM
// +---------+            +---TDM Aggregator FPGA---+           +------+
// |Mic Array|<-MIC_SCK---|                         |---PI_SCK->| Rasp |
// |(M pairs)|<-MIC_WS----|   M Input     Output    |---PI_WS-->| Pi 5 |
// |         |==MIC_SD===>|=> Shifters => Shifter ->|---PI_SD-->| SBC  |
// +---------+   [1:M]    +-------------------------+           +------+
//       clock            clock                 clock           clock
//    consumer    <<      producer           producer     >>    consumer
//
// IMPORTANT NOTES
//
//   * Highly recommended for both SCKs to have source-series termination
//     resistors and for MIC_SCK to use a clock distribution buffer.
//   * WS is not a real clock.  However, both WS and SD may benefit from
//     series resistors to reduce crosstalk aggression and limit current
//     when one connected board is unpowered.
// ------------------------------------------------------------------

module main #(
  parameter int M = `ifdef TDM8    4    // Number of microphone pairs
                    `elsif TDM24  12
                    `endif ,
  parameter int PCM = 2 * 32            // Stereo PCM frame size in bits
) (
  // Clock and Reset
  input  logic         REFCLK,    // PLL reference clock input
  output logic         CORECLK,   // Core clock test output & constraint workaround
  output logic         CORERST,   // Core reset test output

  // Upstream interface with MEMS microphones
  // FPGA is I2S clock producer and data receiver
  output logic         MIC_SCK,   // I2S clock to mics via clock buffer
  output logic         MIC_WS,    // I2S word select to mics
  input  logic  [1:M]  MIC_SD,    // I2S data from mics

  // Downstream interface with Raspberry Pi 5
  // FPGA is I2S clock producer and data transmitter
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

// Pi I2S interface
logic       p_rise;    // Clock enable pulse, rising edge
logic       p_fall;    // Clock enable pulse, falling edge
logic       p_ws_o;    // Word select output to Pi
logic       p_sd_o;    // Data output to Pi

logic       p_aln_i;   // Aligmnent control signal

logic       p_sda_i;   // I2C data input
logic       p_sda_o;   // I2C data output (open drain)
logic       p_scl_i;   // I2C clock input

// ------------------------------------------------------------------

// Clock and reset generator
clkgen #(.M(M)) clkgen (
  .REFCLK,             // input  : PLL reference clock (primary pin)
  .clk,    .rst,       // output : Core clock and reset
  .m_rise, .m_fall,    // output : I2S clock to Mics (clock enable pulses)
  .p_rise, .p_fall     // output : I2S clock to Pi   (clock enable pulses)
  );

// Inteface logic for Input/Output ports
ioports #(.M(M)) ioports (
  .clk,     .rst,      // input  : Core clock and reset
  .ctrl,               // input  : Control register value
  // Pin     Core               Pin       Core
  .MIC_SCK, .m_rise,  .m_fall, .MLB_SCK, .m_sck_li,
  .MIC_WS,  .m_ws_o,           .MLB_WS,  .m_ws_li,
  .MIC_SD,  .m_sd_i,           .MLB_SD,  .m_sd_lo,
  .PI_SCK,  .p_rise,  .p_fall,
  .PI_WS,   .p_ws_o,
  .PI_SD,   .p_sd_o,
  .PI_ALN,  .p_aln_i,
  .PI_SDA,  .p_sda_i, .p_sda_o,
  .PI_SCL,  .p_scl_i
);

// TDM aggregator core logic
tdm #(.M(M), .PCM(PCM)) tdm (
  .clk,    .rst,     // input  : Core clock and reset
  .m_rise, .m_fall,  // input  : I2S clock to Mics (clock enable pulses)
  .m_ws_o,           // output : I2S word select to Mics
  .m_sd_i,           // input  : I2S data input from Mics
  .p_rise, .p_fall,  // input  : I2S clock to Pi   (clock enable pulses)
  .p_ws_o,           // output : I2S word select to Pi
  .p_sd_o,           // output : I2S data to Pi
  .p_aln_i           // input  : Frame alignment control from Pi
  );

// Test pattern generator (internal or external loopback)
tstgen #(.M(M), .PCM(PCM)) tstgen (
  .tpat(ctrl[4]),   // input  : Test pattern select
  .p_aln_i,         // input  : Frame alignment control from Pi
  .m_sck_li,        // input  : I2S clock to Mics
  .m_ws_li,         // input  : I2S word select to Mics
  .m_sd_lo          // output : I2S data from Mics
  );

// Mini I2C Client
i2c i2c (
  .p_sda_i,         // input  : I2C data input
  .p_sda_o,         // output : I2C data output
  .p_scl_i,         // input  : I2C clock input
  .ctrl             // output : Control register value
  );

// ------------------------------------------------------------------

assign CORECLK = clk;  // Test point and constraint workaround
assign CORERST = rst;  // Test point

// Control Register value on first row of LED Matrix
assign LED_R = ~(4'b0001);
assign LED_C = ~(ctrl);

// ------------------------------------------------------------------

endmodule
