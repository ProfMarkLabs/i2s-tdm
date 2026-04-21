// Test Pattern Generator
// PRBS-31 or Tagged Frames
// Works with internal/external loopback and TDM/Mux mode

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

// I2S word select and end of frame (EOF) detection
wire logic ws = m_ws_li;
var  logic wsq;
always @(posedge sck)
  wsq <= ws;
wire logic eof = !wsq && ws;

// Reinitialize LFSR on frame alignment
var logic init = 1;
always @(posedge sck)
  if (eof) init <= aln;

// Rolling frame counter
var logic [15:0] tcnt = '0;
always @(posedge sck)
  if (eof) tcnt <= 16'(tcnt + 1);

generate
for (genvar i = 1; i <= M; i++) begin : mic

  // TODO: Use bitwise implementation to reduce logic utilization

  // Output shifter and LFSR (left and right channels)
  var logic [63:0] next_tsdo, tsdo;
  var logic [30:0] next_tlfsr_L, tlfsr_L, next_tlfsr_R, tlfsr_R;

  always_comb begin
    // Defaults
    next_tsdo = tsdo;
    next_tlfsr_L = tlfsr_L;
    next_tlfsr_R = tlfsr_R;

    if (eof) begin
      if (init) begin
        // Reinitialize registers for frame re-alignment
        // Invalidate data for simulation
        next_tsdo[i] = 'x;
        next_tlfsr_L = 31'(i << 0 | 0 << 12 | i << 16);
        next_tlfsr_R = 31'(i << 0 | 1 << 12 | i << 16);
      end

      else
        // Load shifter for start of next frame based on selected test pattern
        case (tpat)
          0: // PRBS-31
            for (int k = 31; k >= 0; k--) begin
              next_tsdo[32+k] = next_tlfsr_L[30];
              next_tsdo[ 0+k] = next_tlfsr_R[30];
              next_tlfsr_L = {next_tlfsr_L[29:0], next_tlfsr_L[30] ^ next_tlfsr_L[27]};
              next_tlfsr_R = {next_tlfsr_R[29:0], next_tlfsr_R[30] ^ next_tlfsr_R[27]};
            end

          1: // Tagged Frames
            next_tsdo = {8'(i), 8'hAA, 16'(tcnt), 8'(i), 8'hBB, 16'(tcnt)};
        endcase
    end
    else
      // Output shifter with intentional invalidation to catch alignment bugs
      next_tsdo = {tsdo[62:0], 1'bx};
  end

  // Register updates
  // Note: No reset, relies on initial values above
  always_ff @(posedge sck) begin
    tsdo    <= next_tsdo;
    tlfsr_L <= next_tlfsr_L;
    tlfsr_R <= next_tlfsr_R;
  end

  // Data output, MSB-first
  assign m_sd_lo[i] = next_tsdo[63];

end
endgenerate

endmodule
