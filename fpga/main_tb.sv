// FPGA testbench

// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

`timescale 1ns / 1ps

module testbench;

var int ptype  = 0;  // Pi test type: 0:Disable 1:TDM-PRBS 2:TDM-TF 3:Mux-TF
var int monerr = 0;  // Monitor error count
//      pi.chkerr    // Checker error count (FYI)

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
wire logic MIC_SCK;
wire logic MIC_WS;
wire logic [1:M] MIC_SD;

// Pi interface
wire logic PI_SCK;
wire logic PI_WS;
wire logic PI_SD;
var  logic PI_ALN;
wire logic PI_SDA;
wire logic PI_SCL;

// Mic external loopback
wire logic MLB_SCK;
wire logic MLB_WS;
wire logic [1:M] MLB_SD;

// Push-buttons and LED matrix
wire logic [3:0] PB;
wire logic [3:0] LED_R;
wire logic [7:0] LED_C;

// DUT instantiation
main #(.M(M)) dut (.*);

// External loopback
assign MLB_SCK = MIC_SCK;
assign MLB_WS  = MIC_WS;
assign MIC_SD  = MLB_SD;

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
// Pattern checker
// ------------------------------------------------------------------

// Raspberry Pi 5 model
// I2S clock consumer, data input
pi_emu #(.M(M)) pi (.ptype, .SCK(PI_SCK), .WS(PI_WS), .SD(PI_SD));

// Note: Pattern generator is internal to DUT and is used with an
// external or internal loopback in this simulation testbench.

// ------------------------------------------------------------------
// Test sequence
// ------------------------------------------------------------------

initial begin
  $dumpvars(0, testbench);

  ///////////////////////////////////////////////////////////////////////////
  $info("TEST #1: TDM with PRBS-31 (external loopback)");

  // Here we configure the generator (DUT) and checker (Pi model) for
  // PRBS-31, with each microphone using a known unique LFSR seed. We use a
  // GPIO pin to trigger frame alignment, which automatically enables the
  // checker.

  ptype = 0;  // Disabled
  PI_ALN = 1;
  WriteControlRegister(8'h00);  // ilb=0 tpat=0 msel=0 (tdm=1)
  wait (dut.tdm.r_state == dut.tdm.STOP);  // or > 20.8us delay
  ptype = 1;  // TDM with PRBS-31
  PI_ALN = 0;

  #1ms;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////
  $info("TEST #2: TDM with tagged frames (external loopback)");

  // Here we reconfigure the generator (DUT) and checker (Pi model) to use a
  // different test pattern that includes the lane ID, channel, and a frame
  // counter. This time, we test frame alignment via I2C instead of GPIO.

  ptype = 0;  // Disabled
  WriteControlRegister(8'h90);  // aln=1 ilb=0 tpat=1 msel=0 (tdm=1)
  wait (dut.tdm.r_state == dut.tdm.STOP);  // or > 20.8us delay
  ptype = 2;  // TDM with tagged frames
  WriteControlRegister(8'h10);  // aln=0

  #1ms;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////
  $info("TEST #3: Mux with tagged frames (external loopback)");

  // Here we reconfigure the DUT as an I2S multiplexor where, instead of
  // acting as a TDM aggregator from all mics, it simply passes a single
  // stereo channel from one mic pair at a time. Frame alignment is not
  // required for this mode because there is no TDM. However, we reset the
  // checker each time we select a new mic pair, so it will ignore any
  // in-flight frames with the old mic pair ID.

  for (int i = 1; i <= M; i++) begin
    ptype = 0;  // Disabled
    WriteControlRegister(8'h10 | i);  // ilb=0 tpat=1 msel=i (tdm=0)
    ptype = 3;  // Mux with tagged frames
    wait (pi.r_pstate == pi.RUN);
    pi.r_id = i;

    #200us;
    TestSummary;
  end

  ///////////////////////////////////////////////////////////////////////////
  $info("TEST #4: TDM with tagged frames (internal loopback)");

  // We return to TDM aggregation, this time with internal loopback path. We
  // go back to using the GPIO pin for frame alignment. Furthermore, we
  // invalidate the external loopback data to avoid a false pass.

  ptype = 0;  // Disabled
  PI_ALN = 1;
  WriteControlRegister(8'h50);  // ilb=1 tpat=1 msel=0 (tdm=1)
  wait (dut.tdm.r_state == dut.tdm.STOP);  // or > 20.8us delay
  ptype = 2;  // TDM with tagged frames
  PI_ALN = 0;

  force MIC_SD = 'x;  // Invalidate

  #1ms;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////

  $finish;
end

// ------------------------------------------------------------------
// Summary reports
// ------------------------------------------------------------------

// Summary at the end of each test with configuration and error counts
task TestSummary;
  assert (pi.r_pstate === pi.RUN)
    else $error("monerr=%0d : Checker did not reach RUN state!", ++monerr);
  $display("msel=%0d tpat=%0d ilb=%0b tcnt=%0d monerr=%0d chkerr=%0d",
           dut.ioports.msel, dut.tstgen.tpat, dut.ioports.ilb,
           dut.tstgen.tcnt, monerr, pi.r_chkerr);
endtask

// Final summary at end of simulation with error counts
final begin
  bit result;
  string summary;

  result = (monerr == 0 && pi.r_chkerr === 0);
  $sformat(summary, "Simulation %0s with %0d monitor error%0s and %0d checker error%0s",
           result ? "finished" : "FAILED", monerr,      monerr == 1 ? "" : "s",
                                      pi.r_chkerr, pi.r_chkerr == 1 ? "" : "s");
  assert (result) $info (summary);
    else          $error(summary);
end

// ------------------------------------------------------------------
// Datapath monitors
// ------------------------------------------------------------------

// Here we monitor the pipeline and confirm that the data matches where
// expected. This is in addition to the checks done in the Pi model.

// IMPORTANT: We insert frame delays so that the signals line up in the
// simulation waveform for easy comparison.

generate
for (genvar i = 1; i <= M; i++) begin : sigmon

  logic [63:0] tsdo, tsdo_new, tsdo_newer, sdi, sdi_new, sdo, sdo_new, psdi;

  // Test pattern generator
  always begin
    @(negedge dut.tstgen.eof);  // Output shifter reload
    @(negedge dut.tstgen.sck);
    tsdo = tsdo_new;        // 2 frame delay
    tsdo_new = tsdo_newer;  // 1 frame delay
    tsdo_newer[63:32] = dut.tstgen.pair[i].chan[0].r_tsdo;  // Left channel
    tsdo_newer[31: 0] = dut.tstgen.pair[i].chan[1].r_tsdo;  // Right channel
    if (ptype == 3)
      tsdo = tsdo_new;  // Reduced pipeline latency in Mux mode
  end

  // Input data shifter
  always begin
    @(posedge dut.tdm.r_sof);  // Input shift complete
    @(negedge dut.clk);
    sdi = sdi_new;  // 1 frame delay
    sdi_new = dut.tdm.sdi[64*(M-i) +:64];
    if (ptype == 3)
      sdi  = sdi_new;  // Reduced pipeline latency in Mux mode
  end

  // Output data shifter
  always begin
    @(negedge dut.tdm.r_sof);  // Parallel load complete
    @(negedge dut.clk);
    sdo = sdo_new;  // 1 frame delay
    sdo_new = dut.tdm.sdo[64*(M-i) +:64];
    if (ptype == 3)
      sdo = sdi_new;  // Reduced pipeline latency in Mux mode

    // Check output framing of TDM aggregator
    if (dut.tstgen.tcnt > 1)
      assert (dut.tdm.r_pcnt === '0 && PI_WS === 0)
        else $error("monerr=%0d i=%0d pcnt=%0d (exp %0d) PI_WS=%0b (exp %0b)",
                   ++monerr,    i,    dut.tdm.r_pcnt, 0, PI_WS, 0);
  end

  // Pi checker
  always begin
    @(posedge dut.tdm.r_sof);  // Input shift complete
    @(negedge pi.eof);         // Received end of frame
    @(negedge pi.SCK);
    psdi = pi.r_psdi[64*(M-i) +:64];
  end

  // Compare latched data throughout pipeline in middle of each frame
  // Note: Extra conditions help ignore transients at startup and when changing modes
  always begin
    @(posedge MIC_WS);
    if (ptype != 3 && pi.r_pstate == pi.RUN && pi.pstate_old == pi.RUN)
      assert (dut.tstgen.tcnt < 2 || sdi === tsdo && sdo === sdi && psdi === sdo)
        else $error("monerr=%0d i=%0d tsdo=%16h sdi=%16h sdo=%16h psdi=%16h",
                   ++monerr,    i,    tsdo,     sdi,     sdo,     psdi);
  end

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

// Quarter and half cycle delays, based on 100kHz
localparam realtime QD = 2.5us, HD = 5.0us;

task WriteControlRegister (input logic [7:0] ctrl);
  logic [7:0] sr;

  $display("%m: 'h%02h", ctrl);

  // Confirm idle state, then send START condition
  assert (PI_SDA === 1 && PI_SCL === 1)
    else $fatal(0, "monerr=%0d : I2C bus error", ++monerr);
  #HD sda = 0; #HD scl = 0;

  sr = {7'h20, 1'b0};               // Target address byte, WRITE transfer
  repeat (8) begin
    #QD sda = sr[7];
    sr = sr << 1;
    #QD scl = 1;
    #HD scl = 0;
  end
  #QD sda = 1;                   // Release
  #QD scl = 1;
  assert (PI_SDA === 0);            // Check for ACK
  #HD scl = 0;

  sr = ctrl;                        // Write data byte
  repeat (8) begin
    #QD sda = sr[7];
    sr = sr << 1;
    #QD scl = 1;
    #HD scl = 0;
  end
  #QD sda = 1;                   // Release
  #QD scl = 1;
  assert (PI_SDA === 0);            // Check for ACK
  #HD scl = 0;

  // Send STOP condition and minimum idle time
  #QD sda = 0; #QD scl = 1; #HD sda = 1;
  #HD sda = 1;

endtask

// ------------------------------------------------------------------

endmodule
