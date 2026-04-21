// Raspberry Pi 5 - I2S Data Sink Emulator
// (simulation use only)

// I2S clock consumer, data input
// Receives and checks the following:
//  - Frame alignment pattern
//  - TDM with PRBS-31 (ptype=1)
//  - TDM with Tagged Frames (ptype=2)
//  - I2S Mux with Tagged Frames (ptype=3)

// SPDX-FileCopyrightText: (C) 2026 Mark Warriner
// SPDX-License-Identifier: 0BSD

module pi_emu #(

  parameter int M       // Number of mic pairs

  ) (

  input  int    ptype,

  input  logic  SCK,
  input  logic  WS,
  input  logic  SD

  );

typedef enum logic[1:0] {STOP, SYNC0, SYNC1, RUN} state_t;
localparam int C = $clog2(M+1);  // Channel ID: 0:alignment 1:M:running

var state_t pstate_old = STOP, next_pstate = STOP, pstate = STOP;
var logic [M*64-1:0] next_psdi   = '1,   psdi   = '1;  // Input shifter
var logic [C-1:0]    next_id     = '0,   id     = '0;  // Channel ID
var int              next_chkerr = '0,   chkerr = '0;  // Error counter

// I2S word select (WS) and end of frame (EOF) detection
// In TDM mode, EOF occurs during rollover from id=M to id=1
// In Mux mode (ptype=3) or while aligning (id=0), EOF is based solely on WS
var logic wsq = '0;
always_ff @(posedge SCK)
  wsq <= WS;
wire logic eof = !wsq && WS && (id == 0 || id == M || ptype == 3);

// LSFR per mic, seeded to match PRBS generators in mic models
(* ram_style = "logic", mem2reg *)
logic [30:0] next_plfsr_L [1:M], plfsr_L [1:M], next_plfsr_R [1:M], plfsr_R [1:M];
initial
  for (int i = 1; i <= M; i++) begin
    plfsr_L[i] = i << 0 | 0 << 12 | i << 16;
    plfsr_R[i] = i << 0 | 1 << 12 | i << 16;
    next_plfsr_L[i] = plfsr_L[i];
    next_plfsr_R[i] = plfsr_R[i];
  end

// FSM logic
always_comb begin
  // Defaults
  next_pstate = pstate;
  next_psdi   = psdi;
  next_id     = id;
  next_chkerr = chkerr;
  for (int i = 1; i <= M; i++) begin
    next_plfsr_L[i] = plfsr_L[i];
    next_plfsr_R[i] = plfsr_R[i];
  end

  // Capture one full frame of data to facilitate simulation checks
  // Also used for alignment below
  if (ptype == 3) next_psdi = {{(M-1)*64{1'bx}}, psdi[62:0], SD};
  else            next_psdi = {psdi[M*64-2:0], SD};

  if (ptype == 0) begin
    next_pstate = STOP;
    next_id = 0;
  end

  else if (eof) begin
    case (pstate)

      STOP: begin
        next_id = 0;
        // Skip alignment for Mux mode
        if (ptype == 3)
          next_pstate = RUN;
        if (next_psdi === '0)
          // At least one full TDM frame of all 0s
          next_pstate = SYNC0;
      end

      SYNC0:
        if (next_psdi[63:0] === '1)
          // Starting to receive all 1s
          next_pstate = SYNC1;
        else if (next_psdi[63:0] !== '0)
          // Mixed pattern, restart alignment
          next_pstate = STOP;

      SYNC1:
        if (next_psdi === '1) begin
          // Exactly one full TDM frame of all 1s
          next_id = 1;
          next_pstate = RUN;
        end
        else if (next_psdi[63:0] !== '1)
          // Back to all 0s again or mixed pattern
          next_pstate = STOP;

      RUN:
        case (ptype)

        1: // PRBS-31 checker, full TDM frame
          for (int i = 1; i <= M; i++)
            for (int j = 1; j >= 0; j--) begin
              logic [31:0] dat;   // Received data from DUT
              logic [31:0] cmp;   // Comparison data from local LFSR
              logic [30:0] lfsr;  // LFSR holding variable

              //  LSFR for current mic
              if (j) lfsr = plfsr_L[i];
              else   lfsr = plfsr_R[i];

              // Advance LFSR by 32 bits and obtain expected output
              for (int k = 31; k >= 0; k--) begin
                cmp[k] = lfsr[30];
                lfsr = {lfsr[29:0], lfsr[30] ^ lfsr[27]};
              end

              // Write back updated LFSR back to original register
              if (j) next_plfsr_L[i] = lfsr;
              else   next_plfsr_R[i] = lfsr;

              // Compare with actual received data
              dat = next_psdi[(M-i)*64+j*32 +:32];
              if (dat !== cmp)
                next_chkerr++;
            end

        2: // Tagged frame checker, full TDM frame
          for (int i = 1; i <= M; i++) begin
            logic [63:0] tst;  // Check left and right mics together
            tst = next_psdi[(M-i)*64+:64];

            if (!(tst[63:56] === 8'(i) && tst[55:48] === 8'hAA
               && tst[31:24] === 8'(i) && tst[23:16] === 8'hBB))
            next_chkerr++;
          end

        3: // Tagged frame checker, single mic pair
        begin
          logic [63:0] tst;  // Check left and right mics together
          tst = next_psdi[63:0];

          if (!(tst[63:56] === 8'(id) && tst[55:48] === 8'hAA
             && tst[31:24] === 8'(id) && tst[23:16] === 8'hBB))
            next_chkerr++;
        end

        endcase
    endcase
  end

  // For TDM mode (PRBS or tagged frames), select next mic pair
  // For Mux mode, this is handled by the testbench
  if (!wsq && WS && pstate == RUN && ptype != 3)
    next_id = (id % M) + 1;
end

// Register updates
always_ff @(posedge SCK) begin
  pstate <= next_pstate;
  psdi   <= next_psdi;
  id     <= next_id;
  chkerr <= next_chkerr;
  for (int i = 1; i <= M; i++) begin
    plfsr_L[i] <= next_plfsr_L[i];
    plfsr_R[i] <= next_plfsr_R[i];
  end
  if (eof)
    pstate_old <= pstate;  // For testbench monitor
end

endmodule
