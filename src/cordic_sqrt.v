`timescale 1ns / 1ps

// =============================================================================
// Module: cordic_sqrt_optimized
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Hyperbolic CORDIC — Vectoring Mode — for square root computation.
//
// Algorithm:
//   Set  x₀ = a + ¼,  y₀ = a − ¼,  z₀ = 0
//   After 16 iterations:  x_out ≈ K_h · √a
//   where K_h ≈ 0.8282 is the hyperbolic CORDIC gain.
//
// Key differences from circular CORDIC:
//   1. Decision is based on sign of y (drive y → 0), not z.
//   2. x-equation uses ADDITION: x = x + σ·(y>>>j)  (not subtraction).
//   3. Iterations start at j=1 (atanh(2^0) = ∞).
//   4. Iterations j=4 and j=13 are REPEATED for convergence.
//   5. LUT contains atanh(2^-j) instead of atan(2^-j).
//
// Iteration sequence (16 steps total):
//   j = 1, 2, 3, 4, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 14
//
// Input range: a ∈ (0, 0.75) in Q1.15.
// =============================================================================

module cordic_sqrt_optimized #(
  parameter data_width  = 16,
  parameter phase_width = 18,
  parameter n_iterations = 16,
  parameter iter_width  = 4
)(
  input aclk,
  input resetn,

  /* Slave Interface: Initial Values (x0, y0, z0) */
  input signed [data_width-1:0]  x_initial,     // a + 1/4
  input signed [data_width-1:0]  y_initial,     // a - 1/4
  input signed [phase_width-1:0] z_initial,     // 0
  input                          input_valid,
  output                         input_ready,

  /* Look-Up Table Interface (atanh elementary angles) */
  output [iter_width-1:0]            lut_address,
  input  signed [phase_width-1:0]    elementary_angle,

  /* Master Interface: Final Values */
  output reg signed [data_width-1:0]  x_final,  // K_h · √a
  output reg signed [data_width-1:0]  y_final,  // ≈ 0
  output reg signed [phase_width-1:0] z_final,  // atanh(y0/x0)
  output reg                          output_valid,
  input                               output_ready
);

  // ── FSM States ──
  reg [2:0] current_state;
  localparam IDLE   = 3'd0;
  localparam DECIDE = 3'd1;
  localparam Y_POS  = 3'd2;  // y >= 0 → σ = −1
  localparam Y_NEG  = 3'd3;  // y <  0 → σ = +1
  localparam DONE   = 3'd4;

  // ── Internal registers ──
  reg [iter_width-1:0] iteration;             // loop counter 0..15
  reg signed [data_width-1:0]  x_prev, y_prev;
  reg signed [phase_width-1:0] z_prev;

  // ── Shift value mapping ──────────────────────────────────────
  // Maps loop counter (0..15) to the actual shift value j (1..14).
  // Repeats at j=4 (iteration 4) and j=13 (iteration 14).
  // ─────────────────────────────────────────────────────────────
  reg [4:0] shift_j;
  always @(*) begin
    case (iteration)
      4'd0:  shift_j = 5'd1;
      4'd1:  shift_j = 5'd2;
      4'd2:  shift_j = 5'd3;
      4'd3:  shift_j = 5'd4;
      4'd4:  shift_j = 5'd4;   // ← repeat j=4
      4'd5:  shift_j = 5'd5;
      4'd6:  shift_j = 5'd6;
      4'd7:  shift_j = 5'd7;
      4'd8:  shift_j = 5'd8;
      4'd9:  shift_j = 5'd9;
      4'd10: shift_j = 5'd10;
      4'd11: shift_j = 5'd11;
      4'd12: shift_j = 5'd12;
      4'd13: shift_j = 5'd13;
      4'd14: shift_j = 5'd13;  // ← repeat j=13
      4'd15: shift_j = 5'd14;
      default: shift_j = 5'd1;
    endcase
  end

  // ── Shifted values (using shift_j, not iteration) ──
  wire signed [data_width-1:0] x_shifted = x_prev >>> shift_j;
  wire signed [data_width-1:0] y_shifted = y_prev >>> shift_j;

  // ── LUT address = shift_j − 1 (atanh LUT is 0-indexed from j=1) ──
  assign lut_address = shift_j[iter_width-1:0] - 1;

  // ── Input ready when IDLE ──
  assign input_ready = (current_state == IDLE);

  // ── Next values ──
  reg signed [data_width-1:0]  x_next, y_next;
  reg signed [phase_width-1:0] z_next;

  // ── Main FSM ──
  always @(posedge aclk) begin
    if (!resetn) begin
      current_state <= IDLE;
      output_valid  <= 1'b0;
      iteration     <= 0;
      x_prev        <= 0;
      y_prev        <= 0;
      z_prev        <= 0;
    end else begin
      case (current_state)

        // ── IDLE: wait for valid input ──
        IDLE: begin
          output_valid <= 1'b0;
          if (input_valid && input_ready) begin
            x_prev <= x_initial;
            y_prev <= y_initial;
            z_prev <= z_initial;
            iteration <= 0;
            current_state <= DECIDE;
          end
        end

        // ── DECIDE: check sign of y (vectoring mode) ──
        DECIDE: begin
          if (y_prev[data_width-1])   // y < 0
            current_state <= Y_NEG;
          else                        // y >= 0
            current_state <= Y_POS;
        end

        // ── Y_POS / Y_NEG: hyperbolic micro-rotation ──
        Y_POS, Y_NEG: begin
          if (current_state == Y_POS) begin
            // σ = −1 (y ≥ 0, need to decrease y)
            // Hyperbolic (m=−1): x = x − (y>>>j),  y = y − (x>>>j)
            x_next = x_prev - y_shifted;
            y_next = y_prev - x_shifted;
            z_next = z_prev + elementary_angle;
          end else begin
            // σ = +1 (y < 0, need to increase y)
            // Hyperbolic (m=−1): x = x + (y>>>j),  y = y + (x>>>j)
            x_next = x_prev + y_shifted;
            y_next = y_prev + x_shifted;
            z_next = z_prev - elementary_angle;
          end

          // Update registers
          x_prev <= x_next;
          y_prev <= y_next;
          z_prev <= z_next;

          // Loop control
          if (iteration == (n_iterations - 1)) begin
            current_state <= DONE;
          end else begin
            iteration <= iteration + 1;
            current_state <= DECIDE;
          end
        end

        // ── DONE: present output ──
        DONE: begin
          x_final <= x_prev;
          y_final <= y_prev;
          z_final <= z_prev;
          output_valid <= 1'b1;
          if (output_ready)
            current_state <= IDLE;
        end

        default: current_state <= IDLE;
      endcase
    end
  end

endmodule