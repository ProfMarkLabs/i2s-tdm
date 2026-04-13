// Input/Output Ring
// Output registers, test mode muxes, tristate logic, etc.

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module io_ring #(

    parameter int M  // Number of mic pairs

) (

    // External interface (primary pins)

    output logic       SCK,
    output logic       WS,
    input  logic [1:M] SD,

    output logic PI_SCK,
    output logic PI_WS,
    output logic PI_SD,
    input  logic PI_ALN,
    inout  logic PI_SDA,
    input  logic PI_SCL,

    // Core interface

    input logic       clk,
    input logic       rst,
    input logic [7:0] ctrl, // [3:0] Mode 0:TDM 1:M:Mux D:Disabled etc.
                            // [7]   Align

    input  logic       m_rise,  // I2S clock output to mics
    input  logic       m_fall,
    input  logic       m_ws_o,  // I2S word select output to mics
    input  logic [1:M] m_sd_ti, // Test pattern loopback
    output logic [1:M] m_sd_i,  // I2S data input from mics

    input logic p_rise,  // I2S clock output to Pi
    input logic p_fall,
    input logic p_ws_o,  // I2S word select output to Pi
    input logic p_sd_o,  // I2S data output to Pi

    output logic p_aln_i,  // Alignment control input from Pi
    output logic p_sda_i,  // I2C data input from Pi
    input  logic p_sda_o,  // I2C data output to Pi
    output logic p_scl_i   // I2C clock input from Pi

);

// SCK: Output clock generator
// IMPORTANT: Use blocking assignment for generated clocks
initial SCK = 1;
always_ff @(posedge clk)
  if (m_rise) SCK = 1;
  else if (m_fall) SCK = 0;

// WS: Output register, falling edge
// Shadow copy used by I2S mux
initial WS = 0;
var logic m_ws_q = 0;
always_ff @(posedge clk) if (m_fall) {WS, m_ws_q} <= {2{m_ws_o}};

// SD[1:M]: Input with test mux, registered in core logic
always_comb
  case (ctrl[3:0])
    'hD:     m_sd_i = '0;       // Disabled
    'hF:     m_sd_i = m_sd_ti;  // Test pattern loopback
    default: m_sd_i = SD;       // Data from mics
  endcase

// PI_SCK: I2S clock generator
// IMPORTANT: Use blocking assignment for generated clocks
initial PI_SCK = 1;
always_ff @(posedge clk)
  case (ctrl[3:0])
    'hD:     PI_SCK = 0;              // Disabled
    'h0:     if (p_rise) PI_SCK = 1;  // TDM mic data
    'hF:     if (p_rise) PI_SCK = 1;  // TDM test pattern
else if (p_fall) PI_SCK = 0;
    default: if (m_rise) PI_SCK = 1;  // M:1 Mux
else if (m_fall) PI_SCK = 0;
  endcase

// PI_WS: Output register, falling edge
initial PI_WS = 0;
always_ff @(posedge clk)
  case (ctrl[3:0])
    'hD:     PI_WS <= 0;                   // Disabled
    'h0:     if (p_fall) PI_WS <= p_ws_o;  // TDM mic data
    'hF:     if (p_fall) PI_WS <= p_ws_o;  // TDM test pattern
    default: if (m_fall) PI_WS <= m_ws_q;  // M:1 Mux
  endcase

// PI_SD: Output register, falling edge
initial PI_SD = 0;
always_ff @(posedge clk)
  case (ctrl[3:0])
    'hD:     PI_SD <= 0;                   // Disabled
    'h0:     if (p_fall) PI_SD <= p_sd_o;  // TDM mic data
    'hF:     if (p_fall) PI_SD <= p_sd_o;  // TDM test pattern
    default: if (m_fall) PI_SD <= SD[ctrl[3:0]];  // M:1 Mux
  endcase

// PI_ALN: Input synchronizer
var logic [1:0] aln_sync = '0;
always_ff @(posedge clk) aln_sync <= {ctrl[7] | PI_ALN, aln_sync[1]};
assign p_aln_i = aln_sync[0];

// PI_SDA: Bidirectional with open drain driver
assign p_sda_i = PI_SDA;
assign PI_SDA  = p_sda_o ? 1'bz : 1'b0;

// PI_SCL: Input only
assign p_scl_i = PI_SCL;

endmodule
