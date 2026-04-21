// Mini I2C client
// Single 8-bit write-only control register
// Note: See ioports for synchronization and glitch filter

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module i2c #(

  parameter logic [6:0] ADR = 7'h20,  // I2C target address
  parameter logic [7:0] DEF = 8'h00   // Control register default value

)(

  input  logic p_scl_i,    // I2C clock from Pi, input only (no stretching)
  input  logic p_sda_i,    // I2C addr/cmd/data input from Pi
  output logic p_sda_o,    // I2C ACK output to Pi, open-drain: 0 or Z

  output logic [7:0] ctrl  // Control register value to core

);

// ------------------------------------------------------------------

wire logic sda = p_sda_i;
wire logic scl = p_scl_i;

var logic active = 0;      // Active transfer in progress
var logic stop   = 0;      // Asynchronous pulse to reset active

var logic [7:0] sr;        // Input shift register for target address and write data
var logic [4:0] cnt = '0;  // Bit counter: 7 addr + read/write + ACK + 8 data + ACK = 18 bits
var logic       ack =  0;  // Output acknowledge

initial ctrl = DEF;        // Control register default value in FPGA bitstream

// ------------------------------------------------------------------
// START/STOP detection
// ------------------------------------------------------------------

// Pulse width for stop guaranteed by asynchronous handshake
// Reset recovery/removal guaranteed by I2C timing specifications
// REUSE NOTE: This logic does not support repeated START condition (Sr)

always_ff @(negedge sda or posedge stop)
if      (stop) active <= 0;
else if (scl)  active <= 1;  // START condition (S)

always_ff @(posedge sda or negedge active)
if      (!active) stop <= 0;
else if (scl)     stop <= 1;    // STOP condition (P)

// ------------------------------------------------------------------
// Interface logic: SCL rising edge
// ------------------------------------------------------------------

always_ff @(posedge scl or negedge active)

  if (!active) begin
    // Asynchronous reset to idle state
    sr  <= 'x;
    cnt <= '0;
    ack <=  0;
  end

  // Last bit of target address byte
  else if (cnt == 7) begin
    if (sr[6:0] == ADR && sda == 0) begin
      ack <= 1;        // ACK target address byte for WRITE transfer
      cnt <= cnt + 1;  // Bit counter
    end
    else begin
      ack <= 0;        // NACK address mismatch and/or READ transfer
      cnt <= 18;       // Wait for STOP condition
    end
    sr <= 'x;          // Invalidate for simulation
  end

  // Last bit of write data byte
  else if (cnt == 16) begin
    ack  <=  1;              // ACK first data byte
    ctrl <= {sr[6:0], sda};  // Save write data to control register
    cnt  <= cnt + 1;         // Bit counter
    sr   <= 'x;              // Invalidate for simulation
  end

  // Intermediate bits
  else if (cnt < 18) begin
    ack <= 0;                // Disable driver on input bits from Pi
    sr <= {sr[6:0], sda};    // Input data shiter (I2C always MSB-first)
    cnt <= cnt + 1;          // Bit counter
  end

  // Transfer overrun (ignored)
  else
    ack <= 0;  // Disable driver

// ------------------------------------------------------------------
// Interface logic: SCL falling edge
// ------------------------------------------------------------------

// Drive ACK bit on SDA (open-drain)
// REUSE NOTE: This logic does not support READ data output

initial         p_sda_o  = 1;  // High-Z on FPGA config
always_ff @(negedge scl or negedge active)
  if  (!active) p_sda_o <= 1;  // High-Z while idle
  else if (ack) p_sda_o <= 0;  // Drive low for output ACK
  else          p_sda_o <= 1;  // High-Z for output NACK or input bit

// ------------------------------------------------------------------

endmodule
