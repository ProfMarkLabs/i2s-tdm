// I2S TDM Aggregator
// Test Pattern Checker (simulation use only)
// ------------------------------------------------------------------
// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD
// ------------------------------------------------------------------
// DESCRIPTION
//
// This module implements a simulation-based checker for the I2S data
// steam that would be received by the Raspberry Pi 5 single board
// computer (SBC) in real hardware.
//
// DUT interface : I2S clock consumer and data receiver
// TB  interface : Select test type (ptype), observed error count (chkerr)
//    ptype=0      Disabled (I2S interface ignored)
//    ptype 0->N   Frame alignment
//    ptype=1      TDM with PRBS-31
//    ptype=2      TDM with Tagged Frames
//    ptype=3      I2S Mux with Tagged Frames
// ------------------------------------------------------------------

module tstchk_pi #(
  parameter int M,        // Number of mic pairs
  parameter int PCM       // Stereo PCM frame size in bits
) (
  // TB interface
  input  int    ptype,    // Test type select (see above)
  output int    chkerr,   // Cummulative checker error count

  // DUT interface
  input  logic  PI_SCK,   // I2S clock
  input  logic  PI_WS,    // I2S word select
  input  logic  PI_SD     // I2S data (2-channel PCM or 2M-channel TDM)
);

// ------------------------------------------------------------------

typedef enum logic[1:0] {STOP, PRESYNC, SYNC, RUN} state_t;
localparam int C = $clog2(M+1);  // Channel ID: 0:alignment 1:M:running

var state_t pstate_old = STOP, n_pstate = STOP, r_pstate = STOP;
var logic [M*PCM-1:0] n_psdi   = '1,   r_psdi   = '1;  // Input shifter
var logic [C-1:0]     n_id     = '0,   r_id     = '0;  // Channel ID
var int               n_chkerr = '0,   r_chkerr = '0;  // Error counter

// I2S word select (WS) and end of frame (EOF) detection
// In TDM mode, EOF occurs during rollover from id=M to id=1
// In Mux mode (ptype=3) or while aligning (id=0), EOF is based solely on WS
wire logic ws = PI_WS;
var  logic wsq;
always_ff @(posedge PI_SCK)
  wsq <= ws;
wire logic eof = wsq && !ws && (r_id == 0 || r_id == M || ptype == 3);

// LSFR per mic, seeded to match PRBS generators in mic models
logic [30:0] n_plfsr [1:M][0:1], r_plfsr [1:M][0:1];

always_comb begin
  // Defaults
  n_pstate = r_pstate;
  n_psdi   = r_psdi;
  n_id     = r_id;
  n_chkerr = r_chkerr;
  for (int i = 1; i <= M; i++)
    for (int j = 0 ; j <= 1; j++)
      n_plfsr[i][j] = r_plfsr[i][j];

  // Input shift register
  // Facilitates frame alignment and simulation checks
  if (ptype == 3)
    n_psdi = {{(M-1)*PCM{1'bx}}, r_psdi[PCM-2:0], PI_SD};  // Mux mode
  else
    n_psdi = {r_psdi[M*PCM-2:0], PI_SD};                   // TDM mode

  if (eof) begin
    case (r_pstate)

      STOP: begin
        // Special ID value during frame alignment
        n_id = 0;
        // Reinitialize LFSRs
        for (int i = 1; i <= M; i++)
          for (int j = 0; j <= 1; j++)
          n_plfsr[i][j] = i << 0 | j << 12 | i << 16;
        // Skip alignment for Mux mode
        if (ptype == 3)
          n_pstate = RUN;
        if (n_psdi === '0)
          // At least one full TDM frame of all 0s
          n_pstate = PRESYNC;
      end

      PRESYNC:
        if (n_psdi[63:0] === '1)
          // Starting to receive all 1s
          n_pstate = SYNC;
        else if (n_psdi[63:0] !== '0) begin
          // Mixed pattern, restart alignment
          n_pstate = STOP;
          n_chkerr++;
        end

      SYNC:
        if (n_psdi === '1) begin
          // Exactly one full TDM frame of all 1s
          n_id = 1;
          n_pstate = RUN;
        end
        else if (n_psdi[63:0] !== '1) begin
          // Back to all 0s again or mixed pattern, restart alignment
          n_pstate = STOP;
          n_chkerr++;
        end

      RUN:
        case (ptype)

        1: // PRBS-31 checker, full TDM frame
          for (int i = 1; i <= M; i++)
            for (int j = 0; j <= 1; j++) begin
              logic [PCM/2-1:0] dat;   // Received data from DUT
              logic [PCM/2-1:0] cmp;   // Comparison data from local LFSR
              logic [30:0]      lfsr;  // LFSR holding variable

              // Get LFSR for current mic, advance by 32 bits, then write back
              lfsr = r_plfsr[i][j];
              for (int k = PCM/2-1; k >= 0; k--) begin
                cmp[k] = lfsr[30];
                lfsr = {lfsr[29:0], lfsr[30] ^ lfsr[27]};
              end
              n_plfsr[i][j] = lfsr;

              // Compare with actual received data and record error on mismatch
              dat = n_psdi[(M-i)*64+(1-j)*32 +:32];
              if (dat !== cmp)
                n_chkerr++;
            end

        2: // Tagged frame checker, full TDM frame
          for (int i = 1; i <= M; i++) begin
            logic [PCM-1:0] tst;  // Check left and right mics together
            tst = n_psdi[(M-i)*PCM+:PCM];

            if (!(tst[63:56] === 8'(i) && tst[55:48] === 8'hAA
               && tst[31:24] === 8'(i) && tst[23:16] === 8'hBB))
              n_chkerr++;
          end

        3: // Tagged frame checker, stereo PCM frame from single mic pair
        begin
          logic [PCM-1:0] tst;  // Check left and right mics together
          tst = n_psdi[63:0];

          if (!(tst[63:56] === 8'(r_id) && tst[55:48] === 8'hAA
             && tst[31:24] === 8'(r_id) && tst[23:16] === 8'hBB))
            n_chkerr++;
        end

        endcase
    endcase
  end

  // For TDM mode (PRBS or tagged frames), select next mic pair
  // For Mux mode (ptype=3), this is managed by the testbench
  if (wsq && !ws && r_pstate == RUN && ptype != 3)
    n_id = (r_id % M) + 1;
end

always_ff @(posedge PI_SCK or negedge (|ptype)) begin
  r_pstate <= ptype ? n_pstate : STOP;
  r_psdi   <= ptype ? n_psdi   : 'x;
  r_id     <= ptype ? n_id     : '0;
  r_chkerr <= n_chkerr;
  for (int i = 1; i <= M; i++)
    for (int j = 0; j <= 1; j++)
      r_plfsr[i][j] <= n_plfsr[i][j];
end

// Output cumulative error count to testbench
assign chkerr = r_chkerr;

endmodule
