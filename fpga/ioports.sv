// Logic for Input/Output Ports
// Output registers, input synchronization, test mode muxes, tristate logic

// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module ioports #(

  parameter int M  // Number of mic pairs

  ) (

  // Primary pins
  // Note: Pins with direct connection to core are commented out

//input  logic         REFCLK,
//output logic         CORECLK,

  output logic         MIC_SCK,
  output logic         MIC_WS,
  input  logic  [1:M]  MIC_SD,

  output logic         PI_SCK,
  output logic         PI_WS,
  output logic         PI_SD,
  input  logic         PI_ALN,
  inout  logic         PI_SDA,
  input  logic         PI_SCL,

  input  logic         MLB_SCK,
  input  logic         MLB_WS,
  output logic  [1:M]  MLB_SD,

//input  logic  [3:0]  PB,
//output logic  [3:0]  LED_R,
//output logic  [7:0]  LED_C,

  // Core logic

  input  logic         clk,
  input  logic         rst,
  input  logic  [7:0]  ctrl,

  input  logic         m_rise,    // I2S clock output to mics
  input  logic         m_fall,
  output logic         m_sck_li,  // I2S clock loopback input
  input  logic         m_ws_o,    // I2S word select output to mics
  output logic         m_ws_li,   // I2S word select loopback input
  output logic  [1:M]  m_sd_i,    // I2S data inputs from mics
  input  logic  [1:M]  m_sd_lo,   // I2S data loopback outputs

  input  logic         p_rise,    // I2S clock output to Pi
  input  logic         p_fall,
  input  logic         p_ws_o,    // I2S word select output to Pi
  input  logic         p_sd_o,    // I2S data output to Pi

  output logic         p_aln_i,   // Alignment control input from Pi

  output logic         p_sda_i,   // I2C data input from Pi
  input  logic         p_sda_o,   // I2C data output to Pi
  output logic         p_scl_i    // I2C clock input from Pi

);

// ------------------------------------------------------------------
// Control Register (CR) decoder
// ------------------------------------------------------------------

// Mode/Mic Select
// msel=0   tdm=1 : I2S TDM aggregator (interleave data from all mics)
// msel=1:M tdm=0 : I2S multiplexor    (data from specific mic pair)
wire logic [3:0] msel = ctrl[3:0];
wire logic tdm  = (msel == 0);

// Test Pattern Select
// tpat=0 : PRBS-31 with fixed per-mic seed, reset when aln=1
// tpat=1 : Tagged frames (lane ID + L/R channel + rolling frame counter)
wire logic tpat = ctrl[4];

// Internal Loopback Enable
// ilb=1 : Internal loopback (test pattern)
// ilb=0 : Microphone (real data) or external loopback (test pattern)
wire logic ilb = ctrl[6];

// Alignment Enable (TDM mode only)
// aln=1    : Continuous frames of all 0s
// aln 1->0 : Exactly one frame of all 1s
// aln=0    : Normal TDM stream
wire logic aln = ctrl[7];

// ------------------------------------------------------------------
// Upstream I2S interface with mics
// ------------------------------------------------------------------

// MIC_SCK
// Output clock generator
// Replica for internal loopback
// IMPORTANT: Use blocking assignment for generated clocks
initial MIC_SCK = 1;
var logic m_sck_q = 1;
always_ff @(posedge clk)
  if      (m_rise) {MIC_SCK, m_sck_q} = '1;
  else if (m_fall) {MIC_SCK, m_sck_q} = '0;

// MLB_SCK
// External loopback input with internal loopback mux
// Used as clock for Test Pattern Generator logic
assign m_sck_li = ilb ? m_sck_q : MLB_SCK;

// MIC_WS
// Output register, clocked on falling edge
// Replica for internal loopback
initial MIC_WS = 0;
var logic m_ws_q = 0;
always_ff @(posedge clk)
  if (m_fall) {MIC_WS, m_ws_q} <= {2{m_ws_o}};

// MLB_WS
// External loopback input with internal loopback mux
// Registered in core logic (end-of-frame detection)
assign m_ws_li = ilb ? m_ws_q : MLB_WS;

// MLB_SD[1:M]
// External loopback output, clocked on rising edge (like real mics)
// Replica for internal loopback
initial MLB_SD = 0;
var logic [1:M] m_sd_loq = 0;
always @(posedge m_sck_li)
  MLB_SD <= m_sd_lo;
always @(posedge clk)
  if (m_rise) m_sd_loq = m_sd_lo;

// MIC_SD[1:M]
// Input with internal loopback mux
// Registered in core logic (TDM input shifters)
always_comb
  if (ilb) m_sd_i = m_sd_loq; // Internal loopback (test pat)
  else     m_sd_i = MIC_SD;   // Mics (real data) or ext loopback (test pat)

// ------------------------------------------------------------------
// Downstream I2S interface with Pi
// ------------------------------------------------------------------

// PI_SCK
// Output clock generator
// Select rate for TDM vs Mux mode
// IMPORTANT: Use blocking assignment for generated clocks
initial PI_SCK = 1;
always_ff @(posedge clk)
  if      (tdm ? p_rise : m_rise) PI_SCK = 1;
  else if (tdm ? p_fall : m_fall) PI_SCK = 0;

// PI_WS
// Output register, clocked on falling edge
// Select rate and source for TDM vs Mux mode
initial PI_WS = 0;
always_ff @(posedge clk)
  if      ( tdm && p_fall) PI_WS <= p_ws_o;
  else if (!tdm && m_fall) PI_WS <= m_ws_o;

// PI_SD
// Output register, clocked on falling edge
// Select rate for TDM vs Mux mode
initial PI_SD = 0;
always_ff @(posedge clk)
  if      ( tdm && p_fall) PI_SD <= p_sd_o;
  else if (!tdm && m_fall) PI_SD <= m_sd_i[msel];

// ------------------------------------------------------------------
// Alignment control GPIO from Pi
// ------------------------------------------------------------------

// PI_ALN
// Input synchronizer and source combiner with CR bit
// Update in middle of frame (MIC_WS 1->0) to ensure timing
// IMPORTANT: Must be asserted for at least one frame time (48kHz sample)
var  logic [1:0] aln_sync = '0;
always_ff @(posedge clk) begin
  aln_sync <= {PI_ALN, aln_sync[1]};
  if (m_ws_q && !m_ws_o)
    p_aln_i <= aln_sync[0] || aln;
end

// ------------------------------------------------------------------
// I2C target interface with Pi
// ------------------------------------------------------------------

// Note: I2C inputs require a gltich filter to suppress signal integrity
// artifacts and noise spikes up to 50ns wide. The filter can be analog
// (e.g. RC filter plus Schmitt trigger) or digital, as implemented here.

// Number of cycles to filter, based on peak core clock rate (see clkgen)
localparam int FLT = (M ==  4) ? 3 :  //  8 mics, 116ns at 25.8MHz
                     (M == 12) ? 4 :  // 24 mics, ~50ns at 85.0MHz
                                 0;   // Unsupported

// PI_SDA
// Bidirectional with open drain driver
// Input synchronization and glitch filter
logic [FLT-1:0] dly_sda;
initial p_sda_i = 0;
always_ff @(posedge clk) begin
  dly_sda <= {PI_SDA, dly_sda[FLT-1:1]};
  if      (dly_sda == '1) p_sda_i <= 1;
  else if (dly_sda == '0) p_sda_i <= 0;
end
assign PI_SDA = p_sda_o ? 1'bz : 1'b0;

// PI_SCL
// Operatings as input only (I2C target, no clock stretch)
// Input synchronization and glitch filter
logic [FLT-1:0] dly_scl;
initial p_scl_i = 0;
always_ff @(posedge clk) begin
  dly_scl <= {PI_SCL, dly_scl[FLT-1:1]};
  if      (dly_scl == '1) p_scl_i <= 1;
  else if (dly_scl == '0) p_scl_i <= 0;
end

// ------------------------------------------------------------------

endmodule
