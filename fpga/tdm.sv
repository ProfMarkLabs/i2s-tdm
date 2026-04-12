// I2S TDM Aggregator

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module tdm #(

    parameter int M  // Number of mic pairs

) (

    input logic clk,  // FPGA core clock
    input logic rst,  // Synchronous reset, not currently used

    // Upstream Mic interface
    input  logic       m_rise,  // I2S clock enable pulses
    input  logic       m_fall,
    output logic       m_ws_o,  // I2S word select to mics
    input  logic [1:M] m_sd_i,  // I2S multi-lane data from mics

    // Downstream Pi interface
    input  logic p_rise,  // I2S clock enable pulses
    input  logic p_fall,
    output logic p_ws_o,  // I2S word select to Pi
    output logic p_sd_o,  // I2S TDM data to Pi
    input  logic p_aln_i  // Alignment control from Pi

);

// ------------------------------------------------------------------

// Bit counters for 2 x 32-bit PCM words
var logic [5:0] next_mcnt, mcnt = 32;  // Mic interface
var logic [5:0] next_pcnt, pcnt = 32;  // Pi  interface
var logic next_sof, sof = 0;  // Start of frame (SOF) flag

// Finite state machine, state updated on SOF
typedef enum logic [1:0] {
  STOP,
  SYNC,
  RUN
} state_t;
var state_t next_state, state = RUN;

// Input and output data shifter
(* ram_style = "logic", mem2reg *) var logic [32*2-1:0] next_sdi[1:M], sdi[1:M];
var logic [32*2*M-1:0] next_sdo, sdo;

// ------------------------------------------------------------------

always_comb begin

  // Defaults
  next_mcnt  = mcnt;
  next_pcnt  = pcnt;
  next_sof   = sof;
  next_state = state;
  next_sdo   = sdo;
  for (int i = 1; i <= M; i++) next_sdi[i] = sdi[i];

  // Mic bit counter (mcnt)
  // 64-bit repeating downcounter, clock on falling edge
  if (m_fall) begin
    if (mcnt == 0) next_mcnt = '1;
    else next_mcnt = mcnt - 1;
  end

  // Word select to mics
  // Value based on bit counter
  if (mcnt >= 34) m_ws_o = 1;
  else if (mcnt <= 1) m_ws_o = 1;
  else m_ws_o = 0;

  // Start of frame (SOF) indicator
  // Note: Cleared in logic below
  if (m_rise && mcnt == 0) next_sof = '1;

  // Input data shifters from mics (sdi)
  // Clock on risng edge, MSB <- LSB, invalidate at SOF
  if (m_rise)
    for (int i = 1; i <= M; i++)
    if (sof) next_sdi[i] = {{63{1'bx}}, m_sd_i[i]};
    else next_sdi[i] = {sdi[i][62:0], m_sd_i[i]};

  // Pi bit counter (pcnt)
  // 64-bit repeating downcounter, clock on falling edge
  if (p_fall)
    if (pcnt == 0) next_pcnt = '1;
    else next_pcnt = pcnt - 1;

  // Word select to Pi
  // Value based on bit counter
  if (pcnt >= 34) p_ws_o = 1;
  else if (pcnt <= 1) p_ws_o = 1;
  else p_ws_o = 0;

  // Output data shifter to Pi
  // Clock on falling edge, MSB-first, invalidate input for simulation
  if (p_fall) next_sdo = {sdo[254:0], 1'bx};
  p_sd_o = sdo[255];

  // Process start of frame
  if (p_rise && sof) begin
    next_sof  = 0;  // Clear flag
    next_pcnt = '0;  // Force counter state

    // Frame alignment state machine
    case (state)

      STOP: begin
        // Continuous frames with all zeros
        next_sdo = '0;
        if (!p_aln_i) next_state = SYNC;
      end

      SYNC: begin
        // Single frame with all ones
        next_sdo   = '1;
        next_state = RUN;
      end

      RUN: begin
        // Regular data frame, parallel load from input shifters
        for (int i = 1; i <= M; i++)
          next_sdo[64*(M-i) +:64] = sdi[i];

        // Check for new alignment request
        if (p_aln_i) begin
          next_sdo   = '0;
          next_state = STOP;
        end
      end

      default: begin
        next_sdo   = '0;
        next_state = STOP;
      end
    endcase
  end
end

// Synchronous updates
always_ff @(posedge clk) begin
  mcnt  <= next_mcnt;
  pcnt  <= next_pcnt;
  sof   <= next_sof;
  state <= next_state;
  for (int i = 1; i <= M; i++) sdi[i] <= next_sdi[i];
  sdo <= next_sdo;
end

endmodule
