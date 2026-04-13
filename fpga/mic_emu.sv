// MEMS Mic Emulator

// I2S clock consumer, data output
// Generates alignment pattern + PRBS-31 (mtype=0) and tagged frames (mtype=1)
// Note: For simulation use only

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module mic_emu #(

  parameter bit [7:0]  ID,  // Mic pair ID: 1..M
  parameter bit        LR   // Channel select: 0:Left(WS=1) 1:Right(WS=0)

  ) (

  input  int   mtype,  // Test type: 0:PRBS-31 1:Tagged frames

  input  logic SCK,    // I2S clock to mics
  input  logic WS,     // I2S word select to mics
  output logic SD      // I2S data from mics

  );

typedef enum logic [1:0] {STOP, SYNC, RUN} state_t;
var state_t      next_mstate = STOP, mstate = STOP;
var logic [15:0] next_mfcnt  = '0,   mfcnt = '0;  // Rolling frame counter
var logic [30:0] next_mlfsr  = '0,   mlfsr = '0;  // PRBS-31 LFSR
var logic [31:0] next_msdo   = '0,   msdo  = '0;  // Output shifter

// I2S word select (WS) and end of frame (EOF) detection
var logic wsq = !LR;  // Avoid false detection
always_ff @(posedge SCK)
  wsq <= WS;
wire logic eof = LR ?  wsq && !WS   // LR=1 Right: WS 1->0
                    : !wsq &&  WS;  // LR=0 Left:  WS 0->1

// Note: No reset, relies on initial values above
always_comb begin
  // Defaults
  next_mstate = mstate;
  next_mlfsr  = mlfsr;
  next_msdo   = msdo;
  next_mfcnt  = mfcnt;

  if (eof) begin

    case (mstate)

      STOP: begin
        // A few frames of all 0s
        next_msdo = '0;
        if (mfcnt == 2) begin
          next_mstate = SYNC;
        end
      end

      SYNC: begin
        // Single frame of all 1s
        next_msdo  = '1;
        next_mlfsr = 31'(ID << 0 | LR << 12 | ID << 16);
        next_mstate = RUN;
      end

      RUN:
        case (mtype)
          0:  // PRBS-31 generator, unrolled for 32-bit PCM word
            for (int i = 31; i >= 0; i--) begin
              next_msdo[i] = next_mlfsr[30];
              next_mlfsr = {next_mlfsr[29:0], next_mlfsr[30] ^ next_mlfsr[27]};
            end

          1:  // Tagged frame generator
            next_msdo = {8'(ID), LR ? 8'hBB : 8'hAA, 16'(mfcnt)};

        endcase
    endcase

    // Rolling frame counter
    next_mfcnt = 16'(mfcnt + 1);
  end

  else if (WS != LR)
    // Output shifter with intentional invalidation to catch alignment bugs
    next_msdo = {msdo[30:0], 1'bx};
end

// Register updates
always_ff @(posedge SCK) begin
  mstate <= next_mstate;
  mlfsr  <= next_mlfsr;
  msdo   <= next_msdo;
  mfcnt  <= next_mfcnt;  
end

// Data output, MSB-first, tristate when mic unselected
assign SD = (wsq == LR) ? 1'bz : msdo[31];

endmodule
