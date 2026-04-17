// =============================================================================
// Module: atanh_lut
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Parameterized combinational ROM for hyperbolic CORDIC elementary angles.
//
// Stores atanh(2^-j) for j = 1 .. N_ENTRIES, scaled by 2^(PHASE_WIDTH-1)/1.0.
//
// Unlike the circular atan LUT (which starts at j=0), the hyperbolic LUT
// starts at j=1 because atanh(2^0) = infinity.
//
// Address mapping:
//   address 0  →  atanh(2^-1)
//   address 1  →  atanh(2^-2)
//   ...
//   address 13 →  atanh(2^-14)
//
// Scaling:  value = round(atanh(2^-j) × 2^17)
//           (π is NOT used — these are real-valued hyperbolic angles)
// =============================================================================

`timescale 1ns / 1ps

module atanh_lut #(
  parameter PHASE_WIDTH = 18,
  parameter N_ENTRIES   = 14,
  parameter ADDR_WIDTH  = 4
)(
  input  [ADDR_WIDTH-1:0]          address,
  output reg signed [PHASE_WIDTH-1:0] data
);

  // Combinational look-up
  always @(*) begin
    case (address)
      4'd0:  data = 18'sd71999;  // atanh(2^-1)  = 0.549306
      4'd1:  data = 18'sd33477;  // atanh(2^-2)  = 0.255413
      4'd2:  data = 18'sd16470;  // atanh(2^-3)  = 0.125657
      4'd3:  data = 18'sd8203;   // atanh(2^-4)  = 0.062582
      4'd4:  data = 18'sd4097;   // atanh(2^-5)  = 0.031260
      4'd5:  data = 18'sd2048;   // atanh(2^-6)  = 0.015626
      4'd6:  data = 18'sd1024;   // atanh(2^-7)  = 0.007813
      4'd7:  data = 18'sd512;    // atanh(2^-8)  = 0.003906
      4'd8:  data = 18'sd256;    // atanh(2^-9)  = 0.001953
      4'd9:  data = 18'sd128;    // atanh(2^-10) = 0.000977
      4'd10: data = 18'sd64;     // atanh(2^-11) = 0.000488
      4'd11: data = 18'sd32;     // atanh(2^-12) = 0.000244
      4'd12: data = 18'sd16;     // atanh(2^-13) = 0.000122
      4'd13: data = 18'sd8;      // atanh(2^-14) = 0.000061
      default: data = 18'sd0;
    endcase
  end

endmodule
