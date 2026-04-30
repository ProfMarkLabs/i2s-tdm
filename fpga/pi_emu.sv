// Raspberry Pi 5 - I2S Data Sink Emulator
// (simulation use only)

// I2S clock consumer, data input
// Receives and checks the following:
//  - Frame alignment pattern
//  - TDM with PRBS-31 (ptype=1)
//  - TDM with Tagged Frames (ptype=2)
//  - I2S Mux with Tagged Frames (ptype=3)

// SPDX-DocumentNamespace: https://github.com/ProfMarkLabs/i2s-tdm
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

var state_t pstate_old = STOP, n_pstate = STOP, r_pstate = STOP;
var logic [M*64-1:0] n_psdi   = '1,   r_psdi   = '1;  // Input shifter
var logic [C-1:0]    n_id     = '0,   r_id     = '0;  // Channel ID
var int              n_chkerr = '0,   r_chkerr = '0;  // Error counter

// I2S word select (WS) and end of frame (EOF) detection
// In TDM mode, EOF occurs during rollover from id=M to id=1
// In Mux mode (ptype=3) or while aligning (id=0), EOF is based solely on WS
var logic wsq = '0;
always_ff @(posedge SCK)
  wsq <= WS;
wire logic eof = wsq && !WS && (r_id == 0 || r_id == M || ptype == 3);

// LSFR per mic, seeded to match PRBS generators in mic models
logic [30:0] n_plfsr_L [1:M], r_plfsr_L [1:M], n_plfsr_R [1:M], r_plfsr_R [1:M];

// FSM logic
always_comb begin
  // Defaults
  n_pstate = r_pstate;
  n_psdi   = r_psdi;
  n_id     = r_id;
  n_chkerr = r_chkerr;
  for (int i = 1; i <= M; i++) begin
    n_plfsr_L[i] = r_plfsr_L[i];
    n_plfsr_R[i] = r_plfsr_R[i];
  end

  // Capture one full frame of data to facilitate simulation checks
  // Also used for alignment below
  if (ptype == 3) n_psdi = {{(M-1)*64{1'bx}}, r_psdi[62:0], SD};
  else            n_psdi = {r_psdi[M*64-2:0], SD};

  if (ptype == 0) begin
    n_pstate = STOP;
    n_id = 0;
  end

  else if (eof) begin
    case (r_pstate)

      STOP: begin
        // Special ID value during frame alignment
        n_id = 0;
        // Reinitialize LFSRs
        for (int i = 1; i <= M; i++) begin
          n_plfsr_L[i] = i << 0 | 0 << 12 | i << 16;
          n_plfsr_R[i] = i << 0 | 1 << 12 | i << 16;
        end
        // Skip alignment for Mux mode
        if (ptype == 3)
          n_pstate = RUN;
        if (n_psdi === '0)
          // At least one full TDM frame of all 0s
          n_pstate = SYNC0;
      end

      SYNC0:
        if (n_psdi[63:0] === '1)
          // Starting to receive all 1s
          n_pstate = SYNC1;
        else if (n_psdi[63:0] !== '0)
          // Mixed pattern, restart alignment
          n_pstate = STOP;

      SYNC1:
        if (n_psdi === '1) begin
          // Exactly one full TDM frame of all 1s
          n_id = 1;
          n_pstate = RUN;
        end
        else if (n_psdi[63:0] !== '1)
          // Back to all 0s again or mixed pattern
          n_pstate = STOP;

      RUN:
        case (ptype)

        1: // PRBS-31 checker, full TDM frame
          for (int i = 1; i <= M; i++)
            for (int j = 1; j >= 0; j--) begin
              logic [31:0] dat;   // Received data from DUT
              logic [31:0] cmp;   // Comparison data from local LFSR
              logic [30:0] lfsr;  // LFSR holding variable

              //  LSFR for current mic
              if (j) lfsr = r_plfsr_L[i];
              else   lfsr = r_plfsr_R[i];

              // Advance LFSR by 32 bits and obtain expected output
              for (int k = 31; k >= 0; k--) begin
                cmp[k] = lfsr[30];
                lfsr = {lfsr[29:0], lfsr[30] ^ lfsr[27]};
              end

              // Write back updated LFSR back to original register
              if (j) n_plfsr_L[i] = lfsr;
              else   n_plfsr_R[i] = lfsr;

              // Compare with actual received data
              dat = n_psdi[(M-i)*64+j*32 +:32];
              if (dat !== cmp)
                n_chkerr++;
            end

        2: // Tagged frame checker, full TDM frame
          for (int i = 1; i <= M; i++) begin
            logic [63:0] tst;  // Check left and right mics together
            tst = n_psdi[(M-i)*64+:64];

            if (!(tst[63:56] === 8'(i) && tst[55:48] === 8'hAA
               && tst[31:24] === 8'(i) && tst[23:16] === 8'hBB))
            n_chkerr++;
          end

        3: // Tagged frame checker, single mic pair
        begin
          logic [63:0] tst;  // Check left and right mics together
          tst = n_psdi[63:0];

          if (!(tst[63:56] === 8'(r_id) && tst[55:48] === 8'hAA
             && tst[31:24] === 8'(r_id) && tst[23:16] === 8'hBB))
            n_chkerr++;
        end

        endcase
    endcase
  end

  // For TDM mode (PRBS or tagged frames), select next mic pair
  // For Mux mode, this is handled by the testbench
  if (wsq && !WS && r_pstate == RUN && ptype != 3)
    n_id = (r_id % M) + 1;
end

// Register updates
always_ff @(posedge SCK) begin
  r_pstate <= n_pstate;
  r_psdi   <= n_psdi;
  r_id     <= n_id;
  r_chkerr <= n_chkerr;
  for (int i = 1; i <= M; i++) begin
    r_plfsr_L[i] <= n_plfsr_L[i];
    r_plfsr_R[i] <= n_plfsr_R[i];
  end
  if (eof)
    pstate_old <= r_pstate;  // For testbench monitor
end

endmodule
