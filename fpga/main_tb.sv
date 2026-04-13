// FPGA testbench

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

`timescale 1ns / 1ps

module testbench;

// ------------------------------------------------------------------
// Device under test (DUT)
// ------------------------------------------------------------------

// Number of mic pairs
localparam int M = `ifdef TDM8    4
                   `elsif TDM24  12
                   `endif ;

// Reference clock
var  logic REFCLK;
wire logic CORECLK;

// Mic interface
wire logic SCK;
wire logic WS;
wire logic [1:M] SD;

// Pi interface
wire logic PI_SCK;
wire logic PI_WS;
wire logic PI_SD;
var  logic PI_ALN;
wire logic PI_SDA;
wire logic PI_SCL;

// DUT instantiation
main #(.M(M)) dut (.*);

// ------------------------------------------------------------------
// Clocking
// ------------------------------------------------------------------

// Reference clock, 12MHz
initial REFCLK = 0;
always #42 REFCLK = !REFCLK;

// Hack for incomplete PLL simulation model

logic pll_out = 0;
always #3.876 pll_out = !pll_out;
assign dut.clkgen.pll.PLLOUTGLOBAL = pll_out;

logic pll_lock = 0;
initial #1us pll_lock = 1;
assign dut.clkgen.pll.LOCK = pll_lock;

// ------------------------------------------------------------------
// External models
// ------------------------------------------------------------------

// MEMS microphones
// I2S clock consumer, data output
var int mtype = 0;
generate
for (genvar i = 1; i <= M; i++) begin : mic
  mic_emu #(.ID(i), .LR(0)) L (.mtype, .SCK, .WS, .SD(SD[i]));
  mic_emu #(.ID(i), .LR(1)) R (.mtype, .SCK, .WS, .SD(SD[i]));
end : mic
endgenerate

// Raspberry Pi
// I2S clock consumer, data input
var int ptype = 0;
pi_emu #(.M(M)) pi (.ptype, .SCK(PI_SCK), .WS(PI_WS), .SD(PI_SD));

initial PI_ALN = 0;

// ------------------------------------------------------------------
// Test sequence
// ------------------------------------------------------------------

initial begin
  $dumpvars(0, testbench);

  ///////////////////////////////////////////////////////////////////////////
  $display("TEST #1: TDM with PRBS-31 from mics");

  // At startup, the mic models automatically send an alignment pattern, then
  // start their PRBS generators, each with a different seed. The Pi model
  // waits for the alignment pattern, then runs identically-seeded PRBS
  // checkers for each channel. We just need to let this run.

  #1ms;

  ///////////////////////////////////////////////////////////////////////////
  $display("TEST #2: TDM with tagged frames from mics");

  // Here we reconfigure the generator (mic models) and checker (Pi model)
  // to use a different test pattern that includes the channel ID and a frame
  // counter. We also take this opportunity to test DUT internal frame
  // alignment, using a GPIO pin. Note that the mic models do not send the
  // alignment pattern this time (real mics are not capable of this anyway).

  mtype = 1;
  ptype = 1;

  pi.pstate = pi.STOP;
  pi.id = 0;
  PI_ALN = 1;
  wait (dut.tdm.state == dut.tdm.STOP);
  PI_ALN = 0;

  #1ms;

  ///////////////////////////////////////////////////////////////////////////
  $display("TEST #3: I2S mux with tagged frames from mics");

  // Here we reconfigure the DUT as an I2S multiplexor where, instead of
  // acting as a TDM aggregator from all mics, it simply passes a single
  // stereo channel from one mic pair at a time. Frame alignment is not
  // required for this mode because it's completely determined by WS.

  // TODO: Add automated checking for this test

  ptype = 2;

  pi.pstate = pi.STOP;
  pi.id = 0;

  for (int i = 1; i <= M; i++) begin
    WriteControlRegister(i);
    #100us;
  end

  ///////////////////////////////////////////////////////////////////////////
  $display("TEST #4: TDM with tagged frames from DUT internal generator");

  // We return to TDM aggregation, this time using the internal tagged
  // frame generator in the DUT. We also test realignment via I2C instead
  // of the GPIO pin. To ensure the mics are no longer usable, we disable
  // their clock and invalidate their output data.

  ptype = 1;

  pi.pstate = pi.STOP;
  pi.id = 0;
  // Enable tagged frame generator and realign via I2C
  WriteControlRegister(8'h8F);
  wait (dut.tdm.state == dut.tdm.STOP);
  WriteControlRegister(8'h0F);

  force SD = 'x;  // Invalidate data from mics to avoid false pass

  #1ms;

  ///////////////////////////////////////////////////////////////////////////

  $finish;
end

// Check Pi model for recorded errors
final assert (pi.error == 0)
  else $error("Simulation FAILED with %0d checker errors", pi.error);

// ------------------------------------------------------------------
// Internal data monitors (DEBUG)
// ------------------------------------------------------------------

generate
for (genvar i = 1; i <= M; i++) begin : sigmon

  logic [31:0] msdo_L, msdo_R;
  logic [63:0] msdo, msdo_new, tsdo, tsdo_new, sdi, sdi_new, sdo, sdo_new, psdi;

  // Mic transmitters (each channel)
  always begin
    @(negedge mic[i].L.eof);
    @(negedge SCK);
    msdo_L = mic[i].L.msdo[31:0];

    @(negedge mic[i].R.eof)
    @(negedge SCK);
    msdo_R  = mic[i].R.msdo[31:0];
  end

  always begin
    @(posedge dut.tdm.sof);

    // Test pattern generator
    tsdo = tsdo_new;
    tsdo_new = dut.tstgen.mic[i].tsdo;

    // Mic transmitters (combined)
    msdo = msdo_new;
    msdo_new = msdo_L << 32 | msdo_R << 0;

    // Input data shifter
    sdi = sdi_new;
    sdi_new = dut.tdm.sdi[i];

    @(negedge dut.tdm.sof);

    // Output data shifter
    sdo = sdo_new;
    sdo_new = dut.tdm.sdo[64*(M-i) +:64];

    // Check output framing
    if (mic[i].R.mfcnt > 0 && pi.id > 0 && ptype != 2 && dut.ctrl[3:0] != 'hD && dut.ctrl[3:0] != 'hF)
      assert (dut.tdm.pcnt === '0 && PI_WS === 1)
        else $error("i=%0d pcnt=%0d (exp %0d) PI_WS=%0b (exp %0b)", i, dut.tdm.pcnt, 0, PI_WS, 1);

    @(negedge dut.p_fall);

    // Pi receiver
    psdi = pi.psdi[64*(M-i) +:64];

    // Compare data throughout pipeline
    // Note: Extra conditions help ignore transients while changing modes
    if (ptype != 2 && pi.pstate == pi.RUN && (ptype == 0 || pi.psdi !== '1))
      assert (mic[i].R.mfcnt < 2 || sdi === msdo && sdo === sdi && psdi === sdo)
        else $error("i=%0d %s=%16h sdi=%16h sdo=%16h psdi=%16h",
                     i, dut.ctrl[3:0] == 'hF ? "tsdo" : "msdo",
                        dut.ctrl[3:0] == 'hF ?  tsdo :   msdo, sdi, sdo, psdi);
  end

  wire logic [30:0] plfsr_L = pi.plfsr_L[i];
  wire logic [30:0] plfsr_R = pi.plfsr_R[i];

end : sigmon
endgenerate

// ------------------------------------------------------------------
// I2C host controller model
// ------------------------------------------------------------------

var logic sda = 1;
var logic scl = 1;

pullup(PI_SDA);
pullup(PI_SCL);

assign PI_SDA = sda ? 1'bz : 1'b0;
assign PI_SCL = scl ? 1'bz : 1'b0;

task WriteControlRegister (input logic [7:0] ctrl);
  logic [7:0] sr;

  // Check for idle state and send START condition
  assert (PI_SDA === 1 && PI_SCL === 1);
  #5us sda = 0; #5us scl = 0;

  sr = {7'h20, 1'b0};               // Target address byte, WRITE transfer
  repeat (8) begin
    #2.5us sda = sr[7];
    sr = sr << 1;
    #2.5us scl = 1;
    #5us   scl = 0;
  end
  #2.5us sda = 1;                   // Release
  #2.5us scl = 1;
  assert (PI_SDA === 0);            // Check for ACK
  #5us scl = 0;

  sr = ctrl;                        // Write data byte
  repeat (8) begin
    #2.5us sda = sr[7];
    sr = sr << 1;
    #2.5us scl = 1;
    #5us   scl = 0;
  end
  #2.5us sda = 1;                   // Release
  #2.5us scl = 1;
  assert (PI_SDA === 0);            // Check for ACK
  #5us scl = 0;

  // Send STOP condition and minimum idle time
  #2.5us sda = 0; #2.5us scl = 1; #5us sda = 1;
  #10us;

endtask

// ------------------------------------------------------------------

endmodule
