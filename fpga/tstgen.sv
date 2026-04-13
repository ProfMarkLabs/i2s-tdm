// Test Pattern Generator
// Substitute I2S data from mics with tagged frames

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module tstgen #(

  parameter int M         // Number of mic pairs

  ) (

  input  logic clk,            // Core clock
  input  logic rst,            // Synchronous reset (currently unsed)

  input  logic m_rise,         // I2S clock to mics - clock enable pulses
  input  logic m_fall,
  input  logic m_ws_o,         // I2S word select to mics
  output logic [1:M] m_sd_ti   // I2S data from mics - test pattern

  );

// I2S word select and end of frame (EOF) detection
var  logic ws, wsq;
always @(posedge clk) begin
  if (m_fall) ws  <= m_ws_o;  // FPGA output register
  if (m_rise) wsq <= ws;      // Mic input register
end
wire logic eof = !wsq && ws;

generate
for (genvar i = 1; i <= M; i++) begin : mic

  var logic [63:0] next_tsdo = '0, tsdo = '0;  // Output shifter
  var logic [15:0] next_tcnt = '0, tcnt = '0;  // Rolling frame counter

  // Note: No reset, relies on initial values above
  always_comb begin
    // Defaults
    next_tsdo = tsdo;
    next_tcnt = tcnt;

    if (m_rise) begin
      if (eof) begin
        // Shifter load and counter increment
        next_tsdo = {8'(i), 8'hAA, 16'(tcnt), 8'(i), 8'hBB, 16'(tcnt)};
        next_tcnt = 16'(tcnt + 1);
      end
      else
        // Output shifter with intentional invalidation to catch alignment bugs
        next_tsdo = {tsdo[62:0], 1'bx};
    end
  end

  // Register updates
  always_ff @(posedge clk) begin
    tsdo <= next_tsdo;
    tcnt <= next_tcnt;
  end

  // Data output, MSB-first
  assign m_sd_ti[i] = tsdo[63];

end
endgenerate

endmodule
