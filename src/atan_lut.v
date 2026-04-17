// =============================================================================
// Module: atan_lut
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Combinational ROM containing pre-computed elementary angles for CORDIC.
//
//   atan_lut[j] = round( atan(2^-j) * 2^(PHASE_WIDTH-1) / pi )
//
// For circular CORDIC (rotation/vectoring), these are atan(2^-j).
// The values are scaled so that pi maps to 2^(PHASE_WIDTH-1).
//
// Parameters:
//   PHASE_WIDTH  — bit-width of the phase accumulator (default 18)
//   N_ENTRIES    — number of LUT entries = number of CORDIC iterations
//   ADDR_WIDTH   — ceil(log2(N_ENTRIES)), address bus width
// =============================================================================

`timescale 1ns / 1ps

module atan_lut #(
  parameter PHASE_WIDTH = 18,
  parameter N_ENTRIES   = 16,
  parameter ADDR_WIDTH  = 4
)(
  input  [ADDR_WIDTH-1:0]         address,
  output signed [PHASE_WIDTH-1:0] data
);

  // LUT storage — inferred as combinational logic or distributed ROM
  reg signed [PHASE_WIDTH-1:0] lut [0:N_ENTRIES-1];

  // Pre-computed values: atan(2^-j) * (2^17 / pi)
  // Phase scaling: pi = 2^(PHASE_WIDTH-1) = 2^17 = 131072
  //
  //   j |  atan(2^-j) (deg)  |  Fixed-point value
  // ----+--------------------+---------------------
  //   0 |   45.0000          |  32768
  //   1 |   26.5651          |  19344
  //   2 |   14.0362          |  10221
  //   3 |    7.1250          |   5188
  //   4 |    3.5763          |   2604
  //   5 |    1.7899          |   1303
  //   6 |    0.8952          |    652
  //   7 |    0.4476          |    326
  //   8 |    0.2238          |    163
  //   9 |    0.1119          |     81
  //  10 |    0.0560          |     41
  //  11 |    0.0280          |     20
  //  12 |    0.0140          |     10
  //  13 |    0.0070          |      5
  //  14 |    0.0035          |      3
  //  15 |    0.0017          |      1

  initial begin
    lut[ 0] = 18'sd32768;
    lut[ 1] = 18'sd19344;
    lut[ 2] = 18'sd10221;
    lut[ 3] = 18'sd5188;
    lut[ 4] = 18'sd2604;
    lut[ 5] = 18'sd1303;
    lut[ 6] = 18'sd652;
    lut[ 7] = 18'sd326;
    lut[ 8] = 18'sd163;
    lut[ 9] = 18'sd81;
    lut[10] = 18'sd41;
    lut[11] = 18'sd20;
    lut[12] = 18'sd10;
    lut[13] = 18'sd5;
    lut[14] = 18'sd3;
    lut[15] = 18'sd1;
  end

  // Combinational read — no clock needed, purely addressed ROM
  assign data = lut[address];

endmodule
