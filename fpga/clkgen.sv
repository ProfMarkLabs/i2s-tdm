// Clock Generator

// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module clkgen #(

  parameter int M         // Number of mic pairs

  ) (

  input  logic REFCLK,    // Reference clock (primary input)

  output logic clk,       // Core clock for FPGA
  output logic rst,       // Core reset for FPGA

  output logic m_rise,    // Clock enable pulses to mics (upstream I2S)
  output logic m_fall,
  output logic p_rise,    // Clock enable pulses to Pi (downsteam I2S)
  output logic p_fall

);

// ------------------------------------------------------------------
// Clock Configuration
// ------------------------------------------------------------------

// PLLCLK = REFCLK / (DIVR+1) * (DIVF+1) / 2^DIVQ
// MCLK = PLLCLK / DCNT
// PCLK = MCLK * M
// CORECLK(avg) = MCLK * M * 2
// CORECLK(max) = PLLCLK / <smallest # cycles between CLK_RISE edges>
// ASR = MCLK/32/2   (32-bit PCM x 2 channels)
//
// where M is the number of mic pairs

///////////////////////////////////////
`ifdef TDM8  // 8-mic array

  initial assert (M == 4);

  // PLL configuration
  localparam logic [3:0] DIVR = 4'b0000;     // Reference  DIVR+1 = 1
  localparam logic [6:0] DIVF = 7'b1010101;  // Feedback   DIVF+1 = 86
  localparam logic [2:0] DIVQ = 3'b011;      // Output     2^DIVQ = 8
  localparam logic [2:0] FILTER_RANGE = 3'b001;

  // Core Clock edge locations
  // 1 mic SCK = 6*5 + 2*6 = 42 pll_clk = 6 + 2 = 8 core_clk = 4 PI_SCK
  localparam int DCNT = 42;
  localparam logic [DCNT-1:0]
    CLK_RISE = { {6{5'b10000}}, {2{6'b100000}} },
    CLK_FALL = { {6{5'b00100}}, {2{6'b000100}} };

  // REFCLK = 12MHz     PLLCLK = 129MHz
  // MCLK = 3.0714MHz   PCLK = 12.2857MHz
  // ASR = 47.991kHz = 48kHz -0.02%
  // CORECLK(avg) = 24.5724MHz   CORECLK(max)= 25.8MHz

///////////////////////////////////////
`elsif TDM12  // 24-mic array

  initial assert (M == 12);

  // PLL configuration
  localparam logic [3:0] DIVR = 4'b0000;     // Reference  DIVR+1 = 1
  localparam logic [6:0] DIVF = 7'b1010100;  // Feedback   DIVF+1 = 85
  localparam logic [2:0] DIVQ = 3'b010;      // Output     2^DIVQ = 4
  localparam logic [2:0] FILTER_RANGE = 3'b001;

  // Core Clock edge locations
  // 1 mic SCK = 13*3 + 11*4 = 83 pll_clk = 13 + 11 = 24 core_clk = 12 PI_SCK
  localparam int DCNT = 83;
  localparam logic [DCNT-1:0]
    CLK_RISE = { {13{3'b100}}, {11{4'b1000}} },
    CLK_FALL = { {13{3'b010}}, {11{4'b0010}} };

  // REFCLK = 12MHz     PLLCLK = 255MHz
  // MCLK = 3.0723MHz   PCLK = 36.8675MHz
  // ASR = 48.0045kHz = 48kHz +0.01%
  // CORECLK(avg) = 73.7349MHz    CORECLK(max) = 85MHz

///////////////////////////////////////
`endif

// Clock enable pulse locations
// Follows same pattern for any array size
localparam int SCNT = M * 2;
localparam logic [SCNT-1:0]
  MSCK_RISE = 1 << (M * 2 - 1),  // SCK to mics
  MSCK_FALL = 1 << (M - 1),
  PSCK_RISE = {M{2'b10}},        // SCK to Pi
  PSCK_FALL = {M{2'b01}};

// Configuration checks (simulation only)
initial begin
  // Check for edge conflicts (simultaneous rise and fall)
  assert (( CLK_RISE &  CLK_FALL) == '0);
  assert ((MSCK_RISE & MSCK_FALL) == '0);
  assert ((PSCK_RISE & PSCK_FALL) == '0);

  // Check for proper clock ratios by couting edges
  assert ($countones( CLK_RISE) == M * 2);
  assert ($countones( CLK_FALL) == M * 2);
  assert ($countones(MSCK_RISE) == 1);
  assert ($countones(MSCK_FALL) == 1);
  assert ($countones(PSCK_RISE) == M);
  assert ($countones(PSCK_FALL) == M);
end

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
// Core Clock
// ------------------------------------------------------------------

// Core clock divider
var logic [$clog2(DCNT)-1:0] dcnt = '0;
always_ff @(posedge pll_clk)
  if (dcnt == 0) dcnt <= DCNT - 1;
  else           dcnt <= dcnt - 1;

// Core clock output
// Note: Global buffer (SB_GB) inserted automatically
// IMPORTANT: Use blocking assignment for generated clocks
initial clk = 0;
always_ff @(posedge pll_clk)
  if      (CLK_RISE[dcnt]) clk = 1;
  else if (CLK_FALL[dcnt]) clk = 0;

// Reset synchronizer
var logic [2:0] rst_sync;
always_ff @(posedge clk or negedge pll_lock)
  if (!pll_lock) rst_sync <= '1;
  else           rst_sync <= {1'b0, rst_sync[2:1]};
assign rst = rst_sync[0];

// ------------------------------------------------------------------
// Clock Enable Pulse Generator
// ------------------------------------------------------------------

// Core Clock sub-divider
var logic [$clog2(SCNT)-1:0] scnt = '0;
always_ff @(posedge clk)
  if (scnt == 0) scnt <= SCNT - 1;
  else           scnt <= scnt - 1;

// Clock enable pulses
always_ff @(posedge clk) begin
  m_rise <= MSCK_RISE[scnt];
  m_fall <= MSCK_FALL[scnt];
  p_rise <= PSCK_RISE[scnt];
  p_fall <= PSCK_FALL[scnt];
end

// ------------------------------------------------------------------

endmodule
