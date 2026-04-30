// Test Pattern Generator
// PRBS-31 or Tagged Frames
// Works with internal/external loopback and TDM/Mux mode

// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module tstgen #(

  parameter int M         // Number of mic pairs

  ) (

  input  logic [7:0] ctrl,      // Control Register value
  input  logic       p_aln_i,   // Alignment control input

  input  logic       m_sck_li,  // I2S clock loopback input
  input  logic       m_ws_li,   // I2S word select loopback input
  output logic [1:M] m_sd_lo    // I2S data loopback output

  );

wire logic tpat = ctrl[4];  // Test pattern select
wire logic aln  = p_aln_i;  // Alignment control
wire logic sck = m_sck_li;  // I2S clock

// I2S word select (WS) and end of frame (EOF) detection
wire logic ws = m_ws_li;
var  logic wsq;
always @(posedge sck)
  wsq <= ws;
wire logic eof = wsq && !ws;

// Reinitialize LFSR on frame alignment
var logic init = 1;
always @(posedge sck)
  if (eof) init <= aln;

// Rolling frame counter
var logic [15:0] tcnt = '0;
always @(posedge sck)
  if (eof) tcnt <= 16'(tcnt + 1);

generate
for (genvar i = 1; i <= M; i++) begin : pair
  for (genvar j = 0; j <= 1; j++) begin : chan

    // TODO: Use bitwise implementation to reduce logic utilization

    // Output shifter and LFSR
    var logic [31:0] n_tsdo,  r_tsdo;
    var logic [30:0] n_tlfsr, r_tlfsr;

    always_comb begin
      // Defaults
      n_tsdo  = r_tsdo;
      n_tlfsr = r_tlfsr;

      if (eof) begin
        if (init) begin
          // Reinitialize registers for frame re-alignment
          // Invalidate data for simulation
          n_tsdo  = 'x;
          n_tlfsr = 31'(i << 0 | j << 12 | i << 16);
        end

        else
          // Load shifter for start of next frame based on selected test pattern
          case (tpat)
            0: // PRBS-31
              for (int k = 31; k >= 0; k--) begin
                n_tsdo[k] = n_tlfsr[30];
                n_tlfsr = {n_tlfsr[29:0], n_tlfsr[30] ^ n_tlfsr[27]};
              end

            1: // Tagged Frames
              n_tsdo = {8'(i), j ? 8'hBB : 8'hAA, 16'(tcnt)};

          endcase
      end
      else if (j == wsq)
        // Output shifter with intentional invalidation to catch alignment bugs
        n_tsdo = {r_tsdo[30:0], 1'bx};
    end

    // Register updates
    // Note: No reset, relies on initial values above
    always_ff @(posedge sck) begin
      r_tsdo  <= n_tsdo;
      r_tlfsr <= n_tlfsr;
    end

  end : chan

  // Data output, MSB-first
  assign m_sd_lo[i] = ws ? chan[1].n_tsdo[31]   // Right channel
                         : chan[0].n_tsdo[31];  // Left channel

end : pair
endgenerate

endmodule
