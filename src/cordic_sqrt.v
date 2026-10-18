`timescale 1ns / 1ps

// =============================================================================
// Module: cordic_sqrt
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Hyperbolic CORDIC — Vectoring Mode — for square root computation.
//
// Algorithm:
//   Set  x₀ = a + ¼,  y₀ = a − ¼,  z₀ = 0
//   After n_iterations iterations:  x_out ≈ K_h · √a
//   where K_h ≈ 0.8282 is the hyperbolic CORDIC gain.
//
// Key differences from circular CORDIC:
//   1. Decision is based on sign of y (drive y → 0), not z.
//   2. x-equation uses ADDITION: x = x + σ·(y>>>j)  (not subtraction).
//   3. Iterations start at j=1 (atanh(2^0) = ∞).
//   4. Iterations j=4 and j=13 are REPEATED for convergence.
//   5. LUT contains atanh(2^-j) instead of atan(2^-j).
//
// Iteration sequence (loop counter i = 0 .. n_iterations-1):
//   j(i) = i + 1 − [i >= 4] − [i >= 14]
//   n_iterations = 16 → j = 1, 2, 3, 4, 4, 5, 6, ..., 12, 13, 13, 14
//   n_iterations = 18 → j = 1, 2, 3, 4, 4, 5, 6, ..., 12, 13, 13, 14, 15, 16
//   (the next repeat would be at j = 40, so n_iterations must be <= 40)
//
// The external atanh LUT must hold at least
//   j_max = n_iterations − [n_iterations >= 5] − [n_iterations >= 15]
// entries (address = j − 1); e.g. 14 entries for 16 iterations.
//
// Input range: a ∈ (0.03, 0.75) in Q1.(data_width-1).
//
// Phase format: z is Q2.(phase_width-2), i.e. 1.0 = 2^(phase_width-2), so
// the accumulated hyperbolic angle (|z| up to ≈ 1.06 at a = 0.03) never
// wraps. The atanh LUT must use the same scaling (see atanh_lut).
//
// Internal precision: guard_bits extra fractional bits are carried through
// the iterations and x/y are rounded to nearest on output, removing the
// negative bias of the truncating arithmetic shifts.
//
// Interface: valid/ready handshake on both sides. The result is held
//            stable on x/y/z_final while output_valid is high, until
//            output_ready is seen.
//
// Latency: 1 (capture) + n_iterations cycles to output_valid.
// =============================================================================

module cordic_sqrt #(
  parameter data_width  = 16,
  parameter phase_width = 18,
  parameter n_iterations = 16,
  parameter iter_width  = 4,
  parameter guard_bits  = 2
)(
  input aclk,
  input resetn,

  /* Slave Interface: Initial Values (x0, y0, z0) */
  input signed [data_width-1:0]  x_initial,     // a + 1/4
  input signed [data_width-1:0]  y_initial,     // a - 1/4
  input signed [phase_width-1:0] z_initial,     // 0 (Q2.(phase_width-2))
  input                          input_valid,
  output                         input_ready,

  /* Look-Up Table Interface (atanh elementary angles) */
  output [iter_width-1:0]            lut_address,
  input  signed [phase_width-1:0]    elementary_angle,

  /* Master Interface: Final Values */
  output reg signed [data_width-1:0]  x_final,  // K_h · √a
  output reg signed [data_width-1:0]  y_final,  // ≈ 0
  output reg signed [phase_width-1:0] z_final,  // z0 + atanh(y0/x0), Q2.(phase_width-2)
  output reg                          output_valid,
  input                               output_ready
);

  // ── Elaboration-time parameter checks ──
  generate
    if (n_iterations > (1 << iter_width)) begin : g_check_iter
      ERROR_cordic_sqrt_n_iterations_exceeds_iter_width u_param_error ();
    end
    if (n_iterations > 40) begin : g_check_range
      ERROR_cordic_sqrt_n_iterations_must_be_at_most_40 u_param_error ();
    end
  endgenerate

  // ── FSM States ──
  localparam [1:0] IDLE    = 2'd0;
  localparam [1:0] ITERATE = 2'd1;
  localparam [1:0] DONE    = 2'd2;

  localparam integer          LAST_ITER_INT = n_iterations - 1;
  localparam [iter_width-1:0] LAST_ITER     = LAST_ITER_INT[iter_width-1:0];

  // Internal datapath width
  localparam DW = data_width + guard_bits;

  reg [1:0] current_state;

  // ── Internal registers ──
  reg [iter_width-1:0]         iteration;     // loop counter 0..n_iterations-1
  reg signed [DW-1:0]          x_prev, y_prev;
  reg signed [phase_width-1:0] z_prev;

  // ── Shift value mapping ──────────────────────────────────────
  // Maps loop counter i to the actual shift value j, repeating
  // j = 4 (at i = 4) and j = 13 (at i = 14).
  // ─────────────────────────────────────────────────────────────
  wire repeat_4  = (iteration >= 4);
  wire repeat_13 = (iteration >= 14);

  // LUT address = j − 1 (atanh LUT is 0-indexed from j=1)
  assign lut_address = iteration - {{(iter_width-1){1'b0}}, repeat_4}
                                 - {{(iter_width-1){1'b0}}, repeat_13};

  wire [iter_width:0] shift_j = {1'b0, lut_address} + 1'b1;

  // ── Shifted values ──
  wire signed [DW-1:0] x_shifted = x_prev >>> shift_j;
  wire signed [DW-1:0] y_shifted = y_prev >>> shift_j;

  // ── Hyperbolic micro-rotation (m = −1) ──
  //   y >= 0 → σ = −1:  x = x − (y>>>j),  y = y − (x>>>j),  z = z + atanh
  //   y <  0 → σ = +1:  x = x + (y>>>j),  y = y + (x>>>j),  z = z − atanh
  wire y_neg = y_prev[DW-1];

  wire signed [DW-1:0]          x_next = y_neg ? (x_prev + y_shifted) : (x_prev - y_shifted);
  wire signed [DW-1:0]          y_next = y_neg ? (y_prev + x_shifted) : (y_prev - x_shifted);
  wire signed [phase_width-1:0] z_next = y_neg ? (z_prev - elementary_angle)
                                               : (z_prev + elementary_angle);

  // ── Input / output conditioning ──
  // Inputs gain guard_bits zero LSBs; outputs are rounded to nearest.
  // (implicit sign extension to DW bits, then shifted left by guard_bits)
  /* verilator lint_off WIDTHEXPAND */
  wire signed [DW-1:0] x_init_ext = x_initial;
  wire signed [DW-1:0] y_init_ext = y_initial;
  /* verilator lint_on WIDTHEXPAND */

  wire signed [data_width-1:0] x_round, y_round;

  generate
    if (guard_bits > 0) begin : g_round
      localparam signed [DW-1:0] ROUND_HALF = 1 << (guard_bits-1);
      /* verilator lint_off UNUSEDSIGNAL */
      wire signed [DW-1:0] x_sum = x_next + ROUND_HALF;
      wire signed [DW-1:0] y_sum = y_next + ROUND_HALF;
      /* verilator lint_on UNUSEDSIGNAL */
      assign x_round = x_sum[DW-1:guard_bits];
      assign y_round = y_sum[DW-1:guard_bits];
    end else begin : g_no_round
      assign x_round = x_next;
      assign y_round = y_next;
    end
  endgenerate

  // ── Input ready when IDLE ──
  assign input_ready = (current_state == IDLE);

  // ── Main FSM ──
  always @(posedge aclk) begin
    if (!resetn) begin
      current_state <= IDLE;
      output_valid  <= 1'b0;
      iteration     <= 0;
      x_prev        <= 0;
      y_prev        <= 0;
      z_prev        <= 0;
      x_final       <= 0;
      y_final       <= 0;
      z_final       <= 0;
    end else begin
      case (current_state)

        // ── IDLE: wait for valid input ──
        IDLE: begin
          if (input_valid) begin
            x_prev <= x_init_ext <<< guard_bits;
            y_prev <= y_init_ext <<< guard_bits;
            z_prev <= z_initial;
            iteration <= 0;
            current_state <= ITERATE;
          end
        end

        // ── ITERATE: one hyperbolic micro-rotation per clock ──
        ITERATE: begin
          x_prev <= x_next;
          y_prev <= y_next;
          z_prev <= z_next;
          iteration <= iteration + 1'b1;

          if (iteration == LAST_ITER) begin
            x_final <= x_round;
            y_final <= y_round;
            z_final <= z_next;
            output_valid <= 1'b1;
            current_state <= DONE;
          end
        end

        // ── DONE: hold output until it is accepted ──
        DONE: begin
          if (output_ready) begin
            output_valid  <= 1'b0;
            current_state <= IDLE;
          end
        end

        default: current_state <= IDLE;
      endcase
    end
  end

endmodule
