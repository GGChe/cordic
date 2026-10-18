// =============================================================================
// cordic_sqrt — iterative hyperbolic CORDIC, vectoring mode, for √a
// Author: Gabriel Galeote Checa, 2026 — License: MIT
// =============================================================================
// With x0 = a + ¼, y0 = a − ¼, z0 = 0, drives y → 0 and returns
//   x_final = K_h·√a (K_h ≈ 0.8282),  z_final = z0 + atanh(y0/x0).
// Valid for a ∈ (0.03, 0.75) in Q1.(data_width−1). z is Q2.(phase_width−2)
// so the angle (|z| ≤ ~1.06) never wraps; the atanh LUT uses the same scale.
//
// Shift sequence j(i) = i + 1 − [i ≥ 4] − [i ≥ 14] repeats j = 4 and 13 for
// convergence (next repeat at j = 40, hence n_iterations ≤ 40). The atanh LUT
// needs one entry per distinct j (address = j − 1): 14 for 16 iterations.
//
// Valid/ready handshake on both sides. Latency: 1 + n_iterations cycles.
// =============================================================================

`timescale 1ns / 1ps

module cordic_sqrt #(
  parameter data_width  = 16,
  parameter phase_width = 18,
  parameter n_iterations = 16,
  parameter iter_width  = 4,
  parameter guard_bits  = 2     // extra fractional bits; outputs are rounded
)(
  input aclk,
  input resetn,

  input signed [data_width-1:0]  x_initial,     // a + 1/4
  input signed [data_width-1:0]  y_initial,     // a - 1/4
  input signed [phase_width-1:0] z_initial,     // usually 0
  input                          input_valid,
  output                         input_ready,

  output [iter_width-1:0]            lut_address,
  input  signed [phase_width-1:0]    elementary_angle,

  output reg signed [data_width-1:0]  x_final,  // K_h · √a
  output reg signed [data_width-1:0]  y_final,  // ≈ 0
  output reg signed [phase_width-1:0] z_final,
  output reg                          output_valid,
  input                               output_ready
);

  // Invalid parameters abort elaboration (undefined module).
  generate
    if (n_iterations > (1 << iter_width)) begin : g_check_iter
      ERROR_cordic_sqrt_n_iterations_exceeds_iter_width u_param_error ();
    end
    if (n_iterations > 40) begin : g_check_range
      ERROR_cordic_sqrt_n_iterations_must_be_at_most_40 u_param_error ();
    end
  endgenerate

  localparam [1:0] IDLE    = 2'd0;
  localparam [1:0] ITERATE = 2'd1;
  localparam [1:0] DONE    = 2'd2;

  localparam integer          LAST_ITER_INT = n_iterations - 1;
  localparam [iter_width-1:0] LAST_ITER     = LAST_ITER_INT[iter_width-1:0];

  localparam DW = data_width + guard_bits;

  reg [1:0] current_state;

  reg [iter_width-1:0]         iteration;
  reg signed [DW-1:0]          x_prev, y_prev;
  reg signed [phase_width-1:0] z_prev;

  // Loop counter i → LUT address j − 1 and shift j
  wire repeat_4  = (iteration >= 4);
  wire repeat_13 = (iteration >= 14);

  assign lut_address = iteration - {{(iter_width-1){1'b0}}, repeat_4}
                                 - {{(iter_width-1){1'b0}}, repeat_13};

  wire [iter_width:0] shift_j = {1'b0, lut_address} + 1'b1;

  wire signed [DW-1:0] x_shifted = x_prev >>> shift_j;
  wire signed [DW-1:0] y_shifted = y_prev >>> shift_j;

  // Hyperbolic micro-rotation: σ = −sign(y)
  wire y_neg = y_prev[DW-1];

  wire signed [DW-1:0]          x_next = y_neg ? (x_prev + y_shifted) : (x_prev - y_shifted);
  wire signed [DW-1:0]          y_next = y_neg ? (y_prev + x_shifted) : (y_prev - x_shifted);
  wire signed [phase_width-1:0] z_next = y_neg ? (z_prev - elementary_angle)
                                               : (z_prev + elementary_angle);

  // Inputs: sign-extend to DW bits (shifted by guard_bits on capture)
  /* verilator lint_off WIDTHEXPAND */
  wire signed [DW-1:0] x_init_ext = x_initial;
  wire signed [DW-1:0] y_init_ext = y_initial;
  /* verilator lint_on WIDTHEXPAND */

  // Outputs: round to nearest, removing the bias of the truncating shifts
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

  assign input_ready = (current_state == IDLE);

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

        IDLE: begin
          if (input_valid) begin
            x_prev <= x_init_ext <<< guard_bits;
            y_prev <= y_init_ext <<< guard_bits;
            z_prev <= z_initial;
            iteration <= 0;
            current_state <= ITERATE;
          end
        end

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

        // Hold the result until it is accepted
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
