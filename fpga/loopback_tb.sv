// ********************************************************
// LOOPBACK build only - DO NOT USE for student projects
// ********************************************************

// FPGA testbench (LOOPBACK)

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

`timescale 1ns / 1ps

module testbench #(

  parameter int M = `ifdef TDM8    4
                    `elsif TDM24  12
                    `endif
  );

// Clocks
var logic REFCLK;
var logic CORECLK;

// Mic interface
wire logic SCK;
wire logic WS;
wire logic [1:M] SD;

// Pi interface
wire logic PI_SCK;
wire logic PI_WS;
wire logic PI_SD;
wire logic PI_ALN;
wire logic PI_SDA;
wire logic PI_SCL;

// Loopbacks
wire logic [1:M] MSD;
wire logic MSCK;
wire logic MWS;
wire logic PSCK;
wire logic PWS;
wire logic PSD;
wire logic PALN;
wire logic PSDA;
wire logic PSCL;

// Generate clocks for simulation
// Note: PLL doesn't have a proper simulation model

initial REFCLK = 0;  // DUT primary input
always #42 REFCLK = !REFCLK;

logic pll_out = 0;
always #3.876 pll_out = !pll_out;
assign dut.clkgen.pll.PLLOUTGLOBAL = pll_out;

logic pll_lock = 0;
initial #1us pll_lock = 1;
assign dut.clkgen.pll.LOCK = pll_lock;

// ------------------------------------------------------------------
// Internal data monitors
// ------------------------------------------------------------------

generate
for (genvar i = 1; i <= M; i++) begin
  logic [63:0] sdi_old, sdi, sdo_old, sdo, psdi;

  always begin
    // Input data shifter
    @(posedge dut.tdm.sof);
    sdi_old = sdi;
    sdi = dut.tdm.sdi[i];

    // Output data shifter
    @(negedge dut.tdm.sof);
    sdo_old = sdo;
    sdo = dut.tdm.sdo[64*(i-1) +:64];
    assert (dut.tdm.pcnt == '0 && PI_WS == 1)
      else $error("i=%0d pcnt=%0d (exp %0d) PI_WS=%0b (exp %0b)", i, dut.tdm.pcnt, 0, PI_WS, 1);

    // Pi receiver
    @(negedge PI_SCK);
    @(negedge PSCK);
    #0;
    psdi = dut.pi_emu.psdi[64*(i-1) +:64];
    assert (sdo_old == sdi_old && psdi == sdo_old)
      else $error("i=%0d sdi_old=%16h sdo_old=%16h psdi=%16h", i, sdi_old, sdo_old, psdi);
  end
end
endgenerate

// External loopback connections
assign MSCK = SCK;
assign MWS = WS;
assign SD = MSD;
assign PSCK = PI_SCK;
assign PWS = PI_WS;
assign PSD = PI_SD;
assign PI_ALN = PALN;
assign PI_SDA = PSDA;
assign PI_SCL = PSCL;

// Instantiate DUT
loopback dut (.*);

// Run test
initial begin
  $dumpvars(0, testbench);
  #1ms;
  $finish;
end

endmodule
