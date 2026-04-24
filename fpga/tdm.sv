// I2S TDM Aggregator
// ------------------------------------------------------------------
// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD
// ------------------------------------------------------------------
// FEATURES
//
//  * Aggregates multiple stereo PCM interfaces into a single TDM stream
//  * Architecture: store-and-forward, gapless (no speed-up)
//  * Offline in-band frame alignment, triggered by an external signal
//  * Fully synchronous design: common core clock with clock enable pulses
//  * All outputs combinational (registered in ioports module)
//
//   Clock rate ratio:         MIC_SCK (1) :  clk (2M) : PI_CLK (M)
//   e.g. M=4 PCM=2*32 @ 48kHz    3.072MHz : 24.576MHz : 12.288MHz
//
// EXAMPLE APPLICATION
//
// +-----------+  M x 2ch PCM   +---TDM Aggregator FPGA---+ 1 x TDM  +------+
// | Mic Array |<----MIC_SCK----|                         |--PI_SCK->| Rasp |
// | (M pairs) |<----MIC_WS-----|   M Input     Output    |--PI_WS-->| Pi 5 |
// |           |==MIC_SD[1:M]==>|=> Shifters => Shifter ->|--PI_SD-->| SBC  |
// +-----------+                +-------------------------+          +------+
//         clock                clock                 clock          clock
//      consumer                producer           producer          consumer
// ------------------------------------------------------------------

module tdm #(
  parameter int M,            // Number of mic pairs
  parameter int PCM = 2 * 32  // Stereo PCM frame size in bits
) (
  input logic        clk,     // Core clock
  input logic        rst,     // Synchronous reset

  // Upstream I2S interface with mics
  input  logic       m_rise,  // MIC_SCK: Clock enable pulses
  input  logic       m_fall,
  output logic       m_ws_o,  // MIC_WS: Word select to mics
  input  logic [1:M] m_sd_i,  // MIC_SD[1:M]: M-lane PCM data from mics

  // Downstream I2S interface with Pi (runs M times faster)
  input  logic       p_rise,  // PI_SCK: Clock enable pulses
  input  logic       p_fall,
  output logic       p_ws_o,  // PI_WS: Word select to Pi
  output logic       p_sd_o,  // PI_SD: TDM data to Pi

  input  logic       p_aln_i  // Alignment control from Pi
);

// ------------------------------------------------------------------
// Control logic
// ------------------------------------------------------------------

typedef logic [$clog2(PCM)-1:0] cnt_t;                 // Bit counter for WS
typedef enum logic [1:0] { STOP, SYNC, RUN } state_t;  // Frame alignment FSM

// registered value (r), next value (n)
// Note: Due to a simulator limitation, we cannot use a struct here
var cnt_t   r_mcnt,  n_mcnt;   // Mic bit counter
var cnt_t   r_pcnt,  n_pcnt;   // Pi  bit counter (runs M times faster)
var logic   r_sof,   n_sof;    // Flag for start of frame (SOF)
var state_t r_state, n_state;  // FSM state, updated on SOF

// Register update logic
always_ff @(posedge clk)
  if (rst) begin
    r_mcnt  <= PCM / 2;  // Ensure deterministic start for all mics
    r_pcnt  <= PCM / 2;
    r_sof   <= 0;
    r_state <= RUN;  // Frame alignment must be specifically requested
  end
  else begin
    r_mcnt  <= n_mcnt;
    r_pcnt  <= n_pcnt;
    r_sof   <= n_sof;
    r_state <= n_state;
  end

// Determine next state of I2S Word Select (WS)
// Note: WS leads by 2 cycles to keep data aligned to the frame boundary
function bit LeftRight(input cnt_t cnt);
  LeftRight = (cnt >= 2 && cnt < PCM / 2 + 2);  // 0:Left 1:Right
endfunction

// Next value logic
always_comb begin
  // Keep registered values by default
  n_mcnt  = r_mcnt;
  n_pcnt  = r_pcnt;
  n_sof   = r_sof;
  n_state = r_state;

  // Mic bit counter (mcnt) and word select (MIC_WS)
  //  - 64-bit repeating downcounter on MIC_SCK falling edge
  //  - Output based on counter value, registered in ioports module
  if (m_fall)
    if (r_mcnt == 0) n_mcnt = PCM - 1;
    else             n_mcnt--;
  m_ws_o = LeftRight(r_mcnt);

  // Pi bit counter (pcnt) and word select (PI_WS)
  //  - 64-bit repeating downcounter on PI_SCK falling edge
  //  - Output based on counter value, registered in ioports module
  if (p_fall)
    if (r_pcnt == 0) n_pcnt = PCM - 1;
    else             n_pcnt--;
  p_ws_o = LeftRight(r_pcnt);

  // Start of frame (SOF) flag
  //  - Handshake between input and output shifters (sdi -> sdo)
  //  - Raise flag when mic domain finishes a PCM data frame
  //  - Lower flag when Pi domain acknowledges the frame boundary (see below)
  if (m_rise && r_mcnt == 0)
    n_sof = 1;  // Raise flag

  // Alignment state machine (STOP -> SYNC -> RUN)
  //  - Controls pattern delivered to the Pi during frame alignment
  //  - Transitions occur on frame boundaries (SOF) only
  //  - See also: output shifter (sdo) in datapath logic below
  if (p_rise && r_sof) begin
    n_sof  =  0;  // Lower flag
    n_pcnt = '0;  // Force counter state (only needed first time)

    case (r_state)  // PI_ALN or aln=ctrl[7]
      STOP : if (!p_aln_i) n_state = SYNC;  // 1 : Continuous frames of all 0s
      SYNC :               n_state = RUN;   // 1->0 : Single frame of all 1s
      RUN  : if ( p_aln_i) n_state = STOP;  // 0 : Regular TDM data frames
    endcase
  end
end

// ------------------------------------------------------------------
// Datapath logic
// ------------------------------------------------------------------

typedef logic [M*PCM-1:0] frame_t;  // M PCM frames = 1 TDM frame
var frame_t sdi, sdo;

// Input PCM data shifters (MIC_SD[1:M] -> sdi)
//  - M shift registers, each capturing one PCM frame from a mic pair
//  - Shift on MIC_SCK rising edge, MSB-first (shift into LSB)
//  - Invalidate the headspace (not-yet-filled portion) at SOF for simulation
always_ff @(posedge clk)
  if (m_rise)
    for (int b = 0; b < M * PCM; b++)
      if (b % PCM == 0) sdi[b] <= m_sd_i[M-b/PCM];  // Shift in (from mics)
      else if   (r_sof) sdi[b] <= 'x;               // Invalidate (sim only)
      else              sdi[b] <= sdi[b-1];         // Shift along

// Output TDM data shifter (sdo -> PI_SD)
//  - Single shift register to send combined TDM frame to the Pi
//  - Parallel load on SOF, based on alignment state
//  - Shift on falling edge, MSB-first (shift out of MSB)
//  - Invalidate the tail (newly-emptied portion) on each shift for simulation
//  - Output PI_SD from shifter MSB, registered in ioports module
always_ff @(posedge clk)
  if (p_rise && r_sof)
    case (r_state)       // Parallel load:
      STOP: sdo <= '0;   // Continuous frames of all 0s
      SYNC: sdo <= '1;   // Single frame of all 1s
      RUN:  sdo <= sdi;  // Regular TDM data frames
    endcase
  else if (p_fall)
    sdo <= {sdo[M*PCM-2:0], 1'bx};  // Shift along and invalidate (sim only)

assign p_sd_o = sdo[M*PCM-1];  // Output (to Pi)

// ------------------------------------------------------------------

endmodule
