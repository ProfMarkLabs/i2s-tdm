// I2S TDM Aggregator
// Test Pattern Generator
// ------------------------------------------------------------------
// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD
// ------------------------------------------------------------------
// DESCRIPTION
//
// This module implements a synthesizable test pattern generator that
// is included as part of the reference hardware design. It is used
// in simulation and by the test utility running on the Raspberry Pi.
//
// Supports the following test patterns:
//   * PRBS-31 (tpat=0)
//   * Tagged Frames (tpat=1)
//
// Compatible with the following top-level configurations:
//   * Internal Loopback (ilb=1) or External Loopback (ilb=0)
//     Note: Not used when receiving from a real microphone array
//   * TDM mode (tdm=1) or Mux mode (tdm=0)
// ------------------------------------------------------------------

module tstgen #(
  parameter int      M,         // Number of microphone pairs
  parameter int      PCM        // Stereo PCM frame size in bits
) (
  input  logic       tpat,      // Test pattern select 0:PRBS-31 1:TF
  input  logic       p_aln_i,   // Frame alignment control input
  input  logic       m_sck_li,  // Serial Clock (loopback input)
  input  logic       m_ws_li,   // Word Select  (loopback input)
  output logic [1:M] m_sd_lo    // Serial Data  (loopback output)
);

// ------------------------------------------------------------------
// Frame boundary detection
// ------------------------------------------------------------------

wire logic ws = m_ws_li;      // I2S word select (WS)
var  logic wsq;
always @(posedge m_sck_li)
  wsq <= ws;
wire logic eof = wsq && !ws;  // End of frame (EOF)

// ------------------------------------------------------------------
// Common synchronous logic
// ------------------------------------------------------------------

typedef logic [$clog2(PCM)-1:0] cnt_t;                 // Bit counter for WS
typedef logic [15:0] num_t;                            // Rolling frame counter
typedef enum logic [1:0] { STOP, SYNC, RUN } state_t;  // Frame alignment FSM

// registered value (r), next value (n)
var cnt_t   r_tcnt,   n_tcnt;    // Bit counter
var num_t   r_tnum,   n_tnum;    // Rolling frame counter
var state_t r_tstate, n_tstate;  // Frame alignment state

always_comb begin
  // Defaults
  n_tstate = r_tstate;
  n_tcnt   = r_tcnt;
  n_tnum   = r_tnum;

  if (eof) begin
    n_tcnt = 63;  // Sync bit counter (only needed once)

    if (p_aln_i) begin
      n_tstate = STOP;
      n_tnum   = '0;
    end
    else begin
      case (r_tstate)
        STOP : n_tstate = SYNC;
        SYNC : n_tstate = RUN;
        RUN  : n_tstate = RUN;
      endcase
      n_tnum++;   // Rolling frame counter
    end
  end
  else
    n_tcnt--;     // Bit counter
end

always_ff @(posedge m_sck_li) begin
  r_tstate <= n_tstate;
  r_tcnt   <= n_tcnt;
  r_tnum   <= n_tnum;
end

// ------------------------------------------------------------------
// Per-microphone synchronous logic
// ------------------------------------------------------------------

generate
for (genvar i = 1; i <= M; i++) begin : pair
  for (genvar j = 0; j <= 1; j++) begin : chan

    var logic [30:0] n_tlfsr, r_tlfsr;  // PRBS-31 LFSR (next, registered)
    var logic tsdo;                     // Output data bit (combinational)

    always_comb begin
      // Defaults
      n_tlfsr = r_tlfsr;
      tsdo = 'x;  // Invalidate for simulation

      if (n_tstate == STOP && eof)
        // Initialize for frame alignment
        n_tlfsr = 31'(i << 0 | j << 12 | i << 16);

      else if (n_tstate == RUN && ws == j)
        case (tpat)
          0: begin
            // PRBS-31 generator
            tsdo = n_tlfsr[30];
            n_tlfsr = {n_tlfsr[29:0], n_tlfsr[30] ^ n_tlfsr[27]};
          end

          1: begin
            // Tagged frame generator
            logic [PCM/2-1:0] data;
            data = {8'(i), j ? 8'hBB : 8'hAA, 16'(n_tnum)};
            tsdo = data[n_tcnt % 32];
            n_tlfsr = 'x;  // Invalidate for simulation
          end
        endcase
    end

    // Register update
    // Note: No reset, relies on initial values above
    always_ff @(posedge m_sck_li)
      r_tlfsr <= n_tlfsr;

  end : chan

  // I2S data, loopback output (registered in ioports module)
  assign m_sd_lo[i] = ws ? chan[1].tsdo   // Right channel
                         : chan[0].tsdo;  // Left channel

end : pair
endgenerate

// ------------------------------------------------------------------

endmodule
