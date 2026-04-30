// Clock Generator
// ------------------------------------------------------------------
// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD
// ------------------------------------------------------------------
// DESCRIPTION
//
// A hybrid frequency synthesizer using a PLL macro and two digital counters
// to create three synchronous clocks with fixed frequency ratio. The clock
// rates closely approximate the desired audio sample rate (ASR) for the
// number of mic-pair lanes (M) and pulse-coded modulation (PCM) frame size.
//
//     Primary pin      MIC_SCK      CORECLK      PI_SCK
//     Global nets      m_rise         clk        p_rise
//                      m_fall                    p_fall
//     Clock type      CE pulses    Generated    CE pulses
//     Freq ratio           1    :     2M     :     M
//     Freq example    ~3.072MHz   ~24.576MHz   ~12.288MHz
//                     M=4, PCM=2*32, ASR=48kHz
//
// Advantages of this architecture:
//   1. High frequency accuracy without a Frac-N PLL.
//   2. Clock to mics is stable, ensuring clean ADC operation.
//   3. Low skew outputs owing to the use of clock enable pulses.
//   4. Easier timing closure with a just-fast-enough core clock.
// ------------------------------------------------------------------

module clkgen #(
  parameter int M,            // Number of mic pairs
  parameter int PCM = 2 * 32  // Stereo PCM frame size in bits
  ) (

  input  logic REFCLK,        // Reference clock (primary input)

  output logic clk,           // FPGA core clock
  output logic rst,           // FPGA core reset

  output logic m_rise,        // Clock enable pulses to mics (upstream I2S)
  output logic m_fall,
  output logic p_rise,        // Clock enable pulses to Pi (downsteam I2S)
  output logic p_fall

);

// ------------------------------------------------------------------
// Clock Configuration
// ------------------------------------------------------------------

///////////////////////////////////////
`ifdef TDM8  // 8-mic array

  initial assert (M == 4 && PCM == 2*32);

  // PLL configuration
  localparam logic [3:0] DIVR = 4'b0000;     // Reference  DIVR+1 = 1
  localparam logic [6:0] DIVF = 7'b1010101;  // Feedback   DIVF+1 = 86
  localparam logic [2:0] DIVQ = 3'b011;      // Output     2^DIVQ = 8
  localparam logic [2:0] FILTER_RANGE = 3'b001;

  // Core Clock edge locations
  // 1 MIC_SCK = 4 PI_SCK = 8 CORECLK = 6*(5 pll_clk) + 2*(6 pll_clk) = 42 pll_clk
  localparam int DCNT = 42;
  localparam logic [DCNT-1:0]
    CLK_RISE = { {6{5'b10000}}, {2{6'b100000}} },
    CLK_FALL = { {6{5'b00100}}, {2{6'b000100}} };

  // REFCLK = 12MHz   M = 4   PCM = 2 * 32
  // pll_clk = REFCLK / (DIVR+1) * (DIVQ+1) / (2^DIVQ) = 129MHz
  // MIC_CLK = pll_clk / DCNT = 3.0714MHz
  // PI_CLK = M * MIC_SCK = 12.2857MHz
  // ASR = MIC_CLK / PCM = 47.991kHz = 48kHz -0.02%
  // CORECLK(avg) = 2 * PI_CLK  = 24.5724MHz
  // CORECLK(max) = pll_clk / 5 = 25.8MHz

///////////////////////////////////////
`elsif TDM24  // 24-mic array

  initial assert (M == 12 && PCM == 2*32);

  // PLL configuration
  localparam logic [3:0] DIVR = 4'b0000;     // Reference  DIVR+1 = 1
  localparam logic [6:0] DIVF = 7'b1010100;  // Feedback   DIVF+1 = 85
  localparam logic [2:0] DIVQ = 3'b010;      // Output     2^DIVQ = 4
  localparam logic [2:0] FILTER_RANGE = 3'b001;
  
  // Core Clock edge locations
  // 1 MIC_SCK = 12 PI_SCK = 24 CORECLK = 13*(3 pll_clk) + 11*(4 pll_clk) = 83 pll_clk
  localparam int DCNT = 83;
  localparam logic [DCNT-1:0]
    CLK_RISE = { {13{3'b100}}, {11{4'b1000}} },
    CLK_FALL = { {13{3'b010}}, {11{4'b0010}} };

  // REFCLK = 12MHz
  // pll_clk = REFCLK / (DIVR+1) * (DIVQ+1) / (2^DIVQ) = 255MHz
  // MIC_CLK = pll_clk / DCNT = 3.0723MHz
  // PI_CLK = M * MIC_SCK = 36.8675MHz
  // ASR = MIC_CLK / PCM = 48.0045kHz = 48kHz +0.01%
  // CORECLK(avg) = 2 * PI_CLK  = 73.7349MHz
  // CORECLK(max) = pll_clk / 3 = 85MHz

///////////////////////////////////////
`endif

// Clock enable pulse locations
// Follows same general pattern for any mic array size
localparam int SCNT = M * 2;
localparam logic [SCNT-1:0]
  MSCK_RISE = 1 << (M * 2 - 1),  // I2S SCK to mics
  MSCK_FALL = 1 << (M - 1),
  PSCK_RISE = {M{2'b10}},        // I2S SCK to Pi
  PSCK_FALL = {M{2'b01}};

// ------------------------------------------------------------------
// Phase-locked loop (PLL)
// ------------------------------------------------------------------

wire logic pll_clk;
wire logic pll_lock;

SB_PLL40_PAD #(
    .FEEDBACK_PATH("SIMPLE"),
    .DIVR(DIVR),
    .DIVF(DIVF),
    .DIVQ(DIVQ),
    .FILTER_RANGE(FILTER_RANGE)
  ) pll (
    .RESETB('1),
    .BYPASS('0),
    .PACKAGEPIN(REFCLK),
    .PLLOUTCORE(),
    .PLLOUTGLOBAL(pll_clk),
    .LOCK(pll_lock),
    .EXTFEEDBACK('0),
    .DYNAMICDELAY('0),
    .LATCHINPUTVALUE('0),
    .SCLK('0),
    .SDI('0),
    .SDO()
  );

// ------------------------------------------------------------------
// Core Clock and Reset
// ------------------------------------------------------------------

// Core clock divider (dcnt)
var logic [$clog2(DCNT)-1:0] dcnt = '0;
always_ff @(posedge pll_clk)
  if (dcnt == 0) dcnt <= DCNT - 1;
  else           dcnt <= dcnt - 1;

// Core clock generator (clk, CORECLK)
// Note: Global clock buffer (SB_GB) inserted automatically
// IMPORTANT: Use blocking assignment for generated clocks
initial clk = 0;
always_ff @(posedge pll_clk)
  if      (CLK_RISE[dcnt]) clk = 1;
  else if (CLK_FALL[dcnt]) clk = 0;

// Reset synchronizer (rst, CORERST)
var logic [2:0] rst_sync;
always_ff @(posedge clk or negedge pll_lock)
  if (!pll_lock) rst_sync <= '1;
  else           rst_sync <= {1'b0, rst_sync[2:1]};
assign rst = rst_sync[0];

// ------------------------------------------------------------------
// Clock Enable Pulse Generator
// ------------------------------------------------------------------

// Core clock sub-divider (scnt)
var logic [$clog2(SCNT)-1:0] scnt = '0;
always_ff @(posedge clk)
  if (scnt == 0) scnt <= SCNT - 1;
  else           scnt <= scnt - 1;

// Clock enable pulses (m_rise, m_fall, p_rise, p_fall)
always_ff @(posedge clk) begin
  m_rise <= MSCK_RISE[scnt];
  m_fall <= MSCK_FALL[scnt];
  p_rise <= PSCK_RISE[scnt];
  p_fall <= PSCK_FALL[scnt];
end

// ------------------------------------------------------------------

endmodule
