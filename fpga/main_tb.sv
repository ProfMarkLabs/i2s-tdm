// I2S TDM Aggregator
// Top-level simulation testbench
// ------------------------------------------------------------------
// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD
// ------------------------------------------------------------------

`timescale 1ns / 1ps

module testbench;

var  int ptype  = 0;  // Test type: 0:Disable 1:TDM-PRBS 2:TDM-TF 3:Mux-TF
var  int cfgerr = 0;  // Configuration error count
var  int monerr = 0;  // Monitor error count
wire int chkerr;      // Checker error count

localparam int MAXERR = 10;  // Maximum number of errors to report in detail

// ------------------------------------------------------------------
// Device under test (DUT)
// ------------------------------------------------------------------

localparam int M = `ifdef TDM8    4    // Number of microphone pairs
                   `elsif TDM24  12
                   `endif ;
localparam int PCM = 2*32;             // Stereo PCM frame size in bits

// Reference clock
var  logic REFCLK;
wire logic CORECLK;
wire logic CORERST;

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
main #(.M(M), .PCM(PCM)) dut (.*);

// Reference clock, 12MHz
initial REFCLK = 0;
always #42 REFCLK = !REFCLK;

// External loopback
assign MLB_SCK = MIC_SCK;
assign MLB_WS  = MIC_WS;
assign MIC_SD  = MLB_SD;

// ------------------------------------------------------------------
// Test pattern checker
// ------------------------------------------------------------------

// Checks DUT output, acting as a simulation model for the Raspberry Pi 5

/*tstchk_pi*/pi_emu #(.M(M), .PCM(PCM)) pi (
  // TB interface
  .ptype,     // input  : Test type selection
  .chkerr,    // output : Cumulative error count

  // DUT interface: I2S clock consumer and data receiver
  .PI_SCK,    // input  : I2S clock from DUT
  .PI_WS,     // input  : I2S word select from DUT
  .PI_SD      // input  : I2S data from DUT
  );

// Note: Test pattern generator is internal to DUT and is used with
// external and internal loopbacks in this simulation testbench.

// ------------------------------------------------------------------
// Test sequence
// ------------------------------------------------------------------

initial begin

  $dumpvars(0, testbench);

  ///////////////////////////////////////////////////////////////////////////
  $display;
  ClockConfig;
  #0;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////
  $display;
  $info("TEST #1: TDM with PRBS-31 (external loopback)");

  // Here we configure the generator (DUT) and checker (Pi model) for
  // PRBS-31, with each microphone using a known unique LFSR seed. We use a
  // GPIO pin to trigger frame alignment, which automatically enables the
  // checker.

  ptype = 0;  // Disabled
  PI_ALN = 1;
  WriteControlRegister(8'h00);  // ilb=0 tpat=0 msel=0 (tdm=1)
  #20.8us;
  assert(dut.tdm.r_state == dut.tdm.STOP) else monerr++;
  ptype = 1;  // TDM with PRBS-31
  PI_ALN = 0;

  #1ms;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////
  $display;
  $info("TEST #2: TDM with tagged frames (external loopback)");

  // Here we reconfigure the generator (DUT) and checker (Pi model) to use a
  // different test pattern that includes the lane ID, channel, and a frame
  // counter. This time, we test frame alignment via I2C instead of GPIO.

  ptype = 0;  // Disabled
  WriteControlRegister(8'h90);  // aln=1 ilb=0 tpat=1 msel=0 (tdm=1)
  #20.8us;
  assert(dut.tdm.r_state == dut.tdm.STOP) else monerr++;
  ptype = 2;  // TDM with tagged frames
  WriteControlRegister(8'h10);  // aln=0

  #1ms;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////
  $display;
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
  $display;  
  $info("TEST #4: TDM with tagged frames (internal loopback)");

  // We return to TDM aggregation, this time with internal loopback path. We
  // go back to using the GPIO pin for frame alignment. Furthermore, we
  // invalidate the external loopback data to avoid a false pass.

  ptype = 0;  // Disabled
  PI_ALN = 1;
  WriteControlRegister(8'h50);  // ilb=1 tpat=1 msel=0 (tdm=1)
  #20.8us;
  assert(dut.tdm.r_state == dut.tdm.STOP) else monerr++;
  ptype = 2;  // TDM with tagged frames
  PI_ALN = 0;

  force MIC_SD = 'x;  // Invalidate

  #1ms;
  TestSummary;

  ///////////////////////////////////////////////////////////////////////////

  $display;
  $finish;
end

// ------------------------------------------------------------------
// Summary reports
// ------------------------------------------------------------------

// Summary at the end of each test
task TestSummary;
  if ($time > 0) begin
    // Sanity checks to ensure we actually tested something
    assert (pi.r_pstate === pi.RUN)
      else $error("monerr=%0d : Checker did not reach RUN state!", ++monerr);
    assert (dut.tstgen.r_tnum > 4)
      else $error("monerr=%0d : Not enough frames generated", ++monerr);

    $display("msel=%0d tpat=%0d ilb=%0b tnum=%0d monerr=%0d chkerr=%0d",
            dut.ioports.msel, dut.tstgen.tpat, dut.ioports.ilb,
            dut.tstgen.r_tnum, monerr, chkerr);
  end
endtask

// Final summary at end of simulation
final begin : FinalSummary
  bit result;      // Overall simulation result: 1:pass 0:fail
  string summary;  // Common report string

  result = (cfgerr == 0 && monerr == 0 && chkerr === 0);
  $sformat(summary, "Simulation %0s with %0d config error%0s, %0d monitor error%0s, and %0d checker error%0s",
           result ? "finished" : "FAILED", cfgerr, cfgerr == 1 ? "" : "s",
                                           monerr, monerr == 1 ? "" : "s",
                                           chkerr, chkerr == 1 ? "" : "s");
  assert (result) $info (summary);
    else          $error(summary);
end : FinalSummary

// ------------------------------------------------------------------
// Clock Generator
// ------------------------------------------------------------------

`define CG dut.clkgen

// Workaround for incomplete PLL simulation model

logic pll_out = 0;
always #3.876 pll_out = !pll_out;
assign `CG.pll.PLLOUTGLOBAL = pll_out;

logic pll_lock = 0;
initial #1us pll_lock = 1;
assign `CG.pll.LOCK = pll_lock;

// Clock frequencies in MHz
const real
  f_REF  = 12.0,                          // Reference clock (REFCLK)
  f_PFD  = f_REF / (`CG.DIVR+1),          // Phase-frequency detector (PFD) inputs
  f_VCO  = f_PFD * (`CG.DIVF+1),          // Voltage-controlled oscillator (VCO) output
  f_OUT  = f_VCO / (2**`CG.DIVQ),         // Phase-locked loop (PLL) macro output (pll_clk)
  f_CORE = 2 * `CG.M * f_OUT / `CG.DCNT,  // Core clock (CORECLK and clk)
  f_MIC  = f_OUT / `CG.DCNT,              // I2S clock to mic array (MIC_SCK and m_rise/fall)
  f_PI   = f_MIC * M;                     // I2S clock to Pi (PI_SCK and p_rise/fall)

// Audio sample rate (ASR) in Hz
const real ASR = f_MIC / `CG.PCM * 1e6, ASR_nom = 48000;

task ClockConfig;
  $info({ "Clock configuration report:\n",
    "  [PLL] DIVR+1=%0d DIVF+1=%0d 2^DIVQ=%0d REF:%2.1fMHz PFD:%2.1fMHz VCO:%4.1fMHz OUT:%3.1fMHz\n",
    "  [dig] M=%0d DCNT=%0d SCNT=%0d CORECLK:%2.4fMHz MIC_SCK:%1.4fMHz PI_SCK:%2.4fMHz\n",
    "  ASR: %0.0f Hz = %0.0f Hz %0s%0.2f%%" },
    `CG.DIVR+1, `CG.DIVF+1, 2**`CG.DIVQ, f_REF, f_PFD, f_VCO, f_OUT,
    `CG.M, `CG.DCNT, `CG.SCNT, f_CORE, f_MIC, f_PI,
    ASR, ASR_nom, ASR >= ASR_nom ? "+" : "", (ASR-ASR_nom)*100.0/ASR_nom);
endtask

// Check the Clock Generator configuration to ensure its validity
initial begin : ClockConfigCheck

  // Parameter consistency throughout hierarchy (just in case)
  assert (M == `CG.M && PCM == `CG.PCM)
    else $error("cfgerr=%0d : Inconsistent parameters", ++cfgerr);

  // Check that PLL clock frequencies are within valid ranges
  assert (f_PFD >=  10 && f_PFD <=  133)
    else $error("cfgerr=%0d : PLL PFD frequency out of range", ++cfgerr);
  assert (f_VCO >= 533 && f_VCO <= 1066)
    else $error("cfgerr=%0d : PLL VCO frequency out of range", ++cfgerr);
  assert (f_OUT >=  16 && f_OUT <=  275)
    else $error("cfgerr=%0d : PLL OUT frequency out of range", ++cfgerr);

  // Core clock divider counter must carry sufficient resolution to generate
  // both edges of the Core Clock that in turn can create the clock enable
  // pulses for both edges of PI_SCK (clock output as data).
  assert (`CG.DCNT >= `CG.M * 2 * 2)
     else $error("cfgerr=%0d : DCNT value too low", ++cfgerr);

  // Check for edge conflicts (simultaneous rise and fall not allowed) and
  // confirm proper clock ratios (1 MIC_SCK : 2M CORECLK (clk) : M PI_SCK)
  // by couting edges in pattern generators
  assert ( (`CG. CLK_RISE & `CG. CLK_FALL) == '0
        && $countones(`CG. CLK_RISE) == `CG.M * 2
        && $countones(`CG. CLK_FALL) == `CG.M * 2 )
    else $error("cfgerr=%0d : CORECLK (clk) has improper edge pattern", ++cfgerr);
  assert ( (`CG.MSCK_RISE & `CG.MSCK_FALL) == '0
        && $countones(`CG.MSCK_RISE) == 1
        && $countones(`CG.MSCK_FALL) == 1 )
    else $error("cfgerr=%0d : MIC_SCK has improper edge pattern", ++cfgerr);
  assert ( (`CG.PSCK_RISE & `CG.PSCK_FALL) == '0
        && $countones(`CG.PSCK_RISE) == `CG.M
        && $countones(`CG.PSCK_FALL) == `CG.M)
    else $error("cfgerr=%0d : PI_SCK has improper edge pattern", ++cfgerr);

  assert (cfgerr == 0) $info (   "Configuration OK"     );
                  else $fatal(0, "Invalid configuration");

end : ClockConfigCheck

// ------------------------------------------------------------------
// Datapath monitors
// ------------------------------------------------------------------

// Here we monitor the pipeline and confirm that the data matches where
// expected. This is in addition to the verification done in tstchk_sim.

// IMPORTANT: We insert frame delays so that the signals line up in the
// simulation waveform for easy comparison.

generate
for (genvar i = 1; i <= M; i++) begin : Monitor

  logic [63:0] tsdo_cap, tsdo, tsdo_new, sdi, sdi_new, sdo, sdo_new, psdi;

  // Test pattern generator
  always @(posedge dut.tstgen.m_sck_li)
    tsdo_cap <= {tsdo_cap[62:0], dut.tstgen.m_sd_lo[i]};
  always begin
    @(posedge dut.tstgen.eof);
    tsdo = tsdo_new;    // 1 frame delay
    tsdo_new = tsdo_cap;
    if (ptype == 3)
      tsdo = tsdo_new;  // Reduced pipeline latency in Mux mode
  end

  // Input data shifter
  always begin
    @(posedge dut.tdm.r_sof);  // Input shift complete
    @(negedge dut.clk);
    sdi = sdi_new;     // 1 frame delay
    sdi_new = dut.tdm.sdi[64*(M-i) +:64];
    if (ptype == 3)
      sdi  = sdi_new;  // Reduced pipeline latency in Mux mode
  end

  // Output data shifter
  always begin
    @(negedge dut.tdm.r_sof);  // Parallel load complete
    @(negedge dut.clk);
    sdo = sdo_new;    // 1 frame delay
    sdo_new = dut.tdm.sdo[64*(M-i) +:64];
    if (ptype == 3)
      sdo = sdi_new;  // Reduced pipeline latency in Mux mode

    // Check output framing of TDM aggregator
    if (dut.tstgen.r_tnum > 1)
      assert (dut.tdm.r_pcnt === '0 && PI_WS === 0)
        else $error("monerr=%0d i=%0d pcnt=%0d (exp %0d) PI_WS=%0b (exp %0b)",
                   ++monerr,    i,    dut.tdm.r_pcnt, 0, PI_WS, 0);
  end

  // Pi checker
  always begin
    @(posedge dut.tdm.r_sof);  // Input shift complete
    @(negedge pi.eof);         // Received end of frame
    @(negedge PI_SCK);
    psdi = pi.r_psdi[64*(M-i) +:64];  // No delay needed
  end

  // Compare latched data throughout pipeline in middle of each frame
  // Note: Extra conditions help ignore transients at startup and when changing modes
  always begin : Compare
    @(posedge MIC_WS);
    if (ptype != 3 && pi.r_pstate == pi.RUN && !(tsdo === 'x && sdi == 'x && sdo == '1 && psdi == '1))
      assert (sdi === tsdo && sdo === sdi && psdi === sdo)
        else if (++monerr <= MAXERR)
          $error("monerr=%0d i=%0d tsdo=%16h sdi=%16h sdo=%16h psdi=%16h",
                  monerr,    i,    tsdo,     sdi,     sdo,     psdi);
        else if (monerr == MAXERR + 1)
          $error("Additional error messages suppressed");
  end : Compare

end : Monitor
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
