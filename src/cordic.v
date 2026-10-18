
// =============================================================================
// Module: cordic
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Circular CORDIC in Rotation Mode
//
// Algorithm:
//   Set x0, y0 to vector coordinates. Set z0 to the rotation angle.
//   After cordic_niter iterations, rotates (x0, y0) by angle z0.
//   Output:
//     x_out ≈ K · (x0·cos(z0) - y0·sin(z0))
//     y_out ≈ K · (y0·cos(z0) + x0·sin(z0))
//     where K ≈ 1.6467 is the circular CORDIC gain parameter.
//
// Key features of circular CORDIC (Rotation Mode):
//   1. Decision is based on sign of z (drive z → 0).
//   2. Equations: x_{i+1} = x_i - σ·(y_i >>> i)
//                 y_{i+1} = y_i + σ·(x_i >>> i)
//   3. Iterations start at i=0.
//   4. Iteration i increments normally (0, 1, 2, ..., 15). No repeated steps.
//   5. LUT contains atan(2^-i).
//
// Full-circle input range:
//   The plain CORDIC iteration only converges for |z0| <= ~99.9°. Angles in
//   the outer quadrants (|z0| > 90°) are folded on input by rotating the
//   vector by π first:  (x, y, z) → (−x, −y, z ∓ π).  Any z0 in [−π, π) is
//   therefore accepted.
//
// Internal precision:
//   x/y carry 2 extra integer bits (gain growth, K·√2 < 4) and guard_bits
//   extra fractional bits. The phase accumulator carries phase_guard_bits
//   extra fractional bits, so the rounding errors of the atan table do not
//   accumulate into the result. Outputs are rounded to nearest and saturated
//   to inout_width, so a result of exactly +1.0 in Q1.15 clips to 32767
//   instead of wrapping to −32768. With the defaults (16 iterations, 4 + 4
//   guard bits) the error is within 1 LSB (bit-accurate model).
//
//   The external atan LUT must be generated at the INTERNAL phase width
//   phase_width + phase_guard_bits (see cordic_top).
//
// Fixed-point convention (defaults):
//   x, y  : Q1.15            (1.0 = 2^15)
//   phase : pi = 2^17        (range [−π, π))
//
// Interface:
//   AXI4-Stream style. The three slave channels are consumed together: their
//   tready signals are asserted only when the core can accept AND all three
//   tvalid are high, so no channel is ever accepted on its own. Each master
//   channel completes its handshake independently.
//
//   A new input is accepted in the same cycle in which the last pending
//   output beat is accepted, so s_axis_*_tready depends combinationally on
//   m_axis_*_tready (allowed by AXI4-Stream; avoid a combinational loop from
//   the outputs back to the inputs).
//
//   The phase master channel carries the RESIDUAL angle (≈ 0), mostly useful
//   for verification. With phase_output = 0 it is disabled: tvalid stays low,
//   tdata stays 0 and m_axis_phase_tready is ignored, so it can be left
//   unconnected (tie it to 0 or 1).
//
// Timing (no back-pressure):
//   Latency    : cordic_niter cycles, counting the input-handshake cycle
//                (the first micro-rotation is done in that same cycle) up to
//                and including the edge where tvalid rises.
//   Throughput : one result every cordic_niter cycles.
//
// Note: Final outputs must be scaled by 1/K ≈ 0.6072 externally
//       (or pre-scale the input vector by 1/K).
// =============================================================================


`timescale 1ns / 1ps

module cordic #(
  parameter inout_width        = 16,
  parameter phase_width        = 18,
  parameter cordic_niter       = 16,
  parameter cordic_niter_width = 4,
  parameter guard_bits         = 4,   // extra fractional bits on x / y (>= 1)
  parameter phase_guard_bits   = 4,   // extra fractional bits on the phase
  parameter phase_output       = 1    // 1: residual-phase master channel enabled
)(
  input aclk,
  input resetn,

  // AXIS4 PROTOCOL SLAVE INTERFACE
  /* slave axis interface */
  input signed [inout_width-1:0] s_axis_x_tdata,
  input s_axis_x_tvalid,
  output s_axis_x_tready,

  input signed [inout_width-1:0] s_axis_y_tdata,
  input s_axis_y_tvalid,
  output s_axis_y_tready,

  input signed [phase_width-1:0] s_axis_phase_tdata,
  input s_axis_phase_tvalid,
  output s_axis_phase_tready,

  /* atan look-up-table interface (internal phase width) */
  output [cordic_niter_width-1:0] atan_lut_address,
  input signed [phase_width+phase_guard_bits-1:0] atan_lut_data,

  /* master axis interface */
  output reg signed [inout_width-1:0] m_axis_x_tdata,
  output reg m_axis_x_tvalid,
  input m_axis_x_tready,

  output reg signed [inout_width-1:0] m_axis_y_tdata,
  output reg m_axis_y_tvalid,
  input m_axis_y_tready,

  output reg signed [phase_width-1:0] m_axis_phase_tdata,
  output reg m_axis_phase_tvalid,
  input m_axis_phase_tready
);

  // ── Elaboration-time parameter checks ──
  generate
    if (cordic_niter > (1 << cordic_niter_width)) begin : g_check_niter
      ERROR_cordic_niter_exceeds_cordic_niter_width u_param_error ();
    end
    if (cordic_niter < 2) begin : g_check_niter_min
      ERROR_cordic_niter_must_be_at_least_2 u_param_error ();
    end
    if (guard_bits < 1) begin : g_check_guard
      ERROR_cordic_guard_bits_must_be_at_least_1 u_param_error ();
    end
  endgenerate

  // ── Internal datapath widths ──
  localparam IW  = inout_width + 2 + guard_bits;    // x / y: + 2 integer growth bits
  localparam PIW = phase_width + phase_guard_bits;  // internal phase

  localparam integer                  LAST_ITER_INT = cordic_niter - 1;
  localparam [cordic_niter_width-1:0] LAST_ITER     = LAST_ITER_INT[cordic_niter_width-1:0];
  localparam integer                  ONE_INT       = 1;
  localparam [cordic_niter_width-1:0] ITER_ONE      = ONE_INT[cordic_niter_width-1:0];

  localparam [0:0] PHASE_EN = (phase_output != 0) ? 1'b1 : 1'b0;

  // ── FSM States ──
  localparam [1:0] IDLE   = 2'd0;
  localparam [1:0] ROTATE = 2'd1;
  localparam [1:0] OUTPUT = 2'd2;

  reg [1:0] cordic_state;
  // CORDIC ITERATION COUNTER (always 0 outside ROTATE)
  reg [cordic_niter_width-1:0] iteration;

  reg signed [IW-1:0]  x_tdata_temp;
  reg signed [IW-1:0]  y_tdata_temp;
  reg signed [PIW-1:0] phase_tdata_temp;

  // ── Master handshake ──
  // A channel's beat is complete once tvalid && tready; it is pending otherwise.
  wire x_pending     = m_axis_x_tvalid     && !m_axis_x_tready;
  wire y_pending     = m_axis_y_tvalid     && !m_axis_y_tready;
  wire phase_pending = m_axis_phase_tvalid && !m_axis_phase_tready;
  wire out_done      = !x_pending && !y_pending && !phase_pending;

  // ── Slave handshake ──
  // All three channels are consumed together, so tready is only asserted
  // when every channel is valid (tready may depend on tvalid in AXI-Stream).
  // A new input is taken while idle, or while the previous result is being
  // accepted in this very cycle.
  wire not_busy     = (cordic_state == IDLE) || (cordic_state == OUTPUT);
  wire all_in_valid = s_axis_x_tvalid && s_axis_y_tvalid && s_axis_phase_tvalid;
  wire in_fire      = not_busy && out_done && all_in_valid;

  assign s_axis_x_tready     = in_fire;
  assign s_axis_y_tready     = in_fire;
  assign s_axis_phase_tready = in_fire;
  assign atan_lut_address    = iteration;

  // ── Input conditioning: sign-extend, add guard bits, quadrant fold ──
  wire signed [IW-1:0] x_in_ext = {{2{s_axis_x_tdata[inout_width-1]}}, s_axis_x_tdata, {guard_bits{1'b0}}};
  wire signed [IW-1:0] y_in_ext = {{2{s_axis_y_tdata[inout_width-1]}}, s_axis_y_tdata, {guard_bits{1'b0}}};

  // Phase: implicit sign extension to PIW bits, then guard bits appended.
  /* verilator lint_off WIDTHEXPAND */
  wire signed [PIW-1:0] z_in_wide = s_axis_phase_tdata;
  /* verilator lint_on WIDTHEXPAND */
  wire signed [PIW-1:0] z_in_ext  = z_in_wide <<< phase_guard_bits;

  // Phase in [π/2, π) or [−π, −π/2) ⇔ the two MSBs differ.
  // Subtracting/adding π (= 2^(PIW-1)) is just an MSB flip.
  wire quadrant_fold = z_in_ext[PIW-1] ^ z_in_ext[PIW-2];

  wire signed [IW-1:0]  x_in_fold = quadrant_fold ? -x_in_ext : x_in_ext;
  wire signed [IW-1:0]  y_in_fold = quadrant_fold ? -y_in_ext : y_in_ext;
  wire signed [PIW-1:0] z_in_fold = quadrant_fold ? {~z_in_ext[PIW-1], z_in_ext[PIW-2:0]} : z_in_ext;

  // ── Micro-rotation (one per clock) ──
  // Outside ROTATE the datapath works on the (folded) input with
  // iteration = 0, so the first micro-rotation happens in the capture cycle.
  wire start = (cordic_state != ROTATE);

  wire signed [IW-1:0]  x_cur = start ? x_in_fold : x_tdata_temp;
  wire signed [IW-1:0]  y_cur = start ? y_in_fold : y_tdata_temp;
  wire signed [PIW-1:0] z_cur = start ? z_in_fold : phase_tdata_temp;

  wire phase_neg = z_cur[PIW-1];

  wire signed [IW-1:0] x_shifted = x_cur >>> iteration;
  wire signed [IW-1:0] y_shifted = y_cur >>> iteration;

  // phase < 0 → clockwise (σ = −1), phase >= 0 → counter-clockwise (σ = +1)
  wire signed [IW-1:0]  x_next     = phase_neg ? (x_cur + y_shifted) : (x_cur - y_shifted);
  wire signed [IW-1:0]  y_next     = phase_neg ? (y_cur - x_shifted) : (y_cur + x_shifted);
  wire signed [PIW-1:0] phase_next = phase_neg ? (z_cur + atan_lut_data) : (z_cur - atan_lut_data);

  // ── Output conditioning: round to nearest, drop guard bits, saturate ──
  localparam signed [IW-1:0]          ROUND_HALF = 1 << (guard_bits-1);
  localparam signed [inout_width-1:0] SAT_MAX    = {1'b0, {(inout_width-1){1'b1}}};
  localparam signed [inout_width-1:0] SAT_MIN    = {1'b1, {(inout_width-1){1'b0}}};

  function signed [inout_width-1:0] round_sat;
    input signed [IW-1:0] value;
    reg   signed [IW-1:0] rounded;
    begin
      rounded = value + ROUND_HALF;
      // In range iff the 2 growth bits equal the output sign bit
      if (rounded[IW-1:IW-3] == 3'b000 || rounded[IW-1:IW-3] == 3'b111)
        round_sat = rounded[IW-3:guard_bits];
      else if (rounded[IW-1])
        round_sat = SAT_MIN;
      else
        round_sat = SAT_MAX;
    end
  endfunction

  wire signed [inout_width-1:0] x_out     = round_sat(x_next);
  wire signed [inout_width-1:0] y_out     = round_sat(y_next);
  // Residual phase back at the interface width (floor; it is only ≈ 0)
  wire signed [phase_width-1:0] phase_out = phase_next[PIW-1:phase_guard_bits];

  always @(posedge aclk) begin
    if (!resetn) begin
      cordic_state <= IDLE;
      m_axis_x_tvalid <= 1'b0;
      m_axis_y_tvalid <= 1'b0;
      m_axis_phase_tvalid <= 1'b0;
      m_axis_x_tdata <= 0;
      m_axis_y_tdata <= 0;
      m_axis_phase_tdata <= 0;
      // Reset internal registers
      x_tdata_temp <= 0;
      y_tdata_temp <= 0;
      phase_tdata_temp <= 0;
      iteration <= 0;
    end else begin
      // Master channels: drop tvalid once the beat has been accepted
      // (overridden below when a new result is presented).
      if (m_axis_x_tready)     m_axis_x_tvalid     <= 1'b0;
      if (m_axis_y_tready)     m_axis_y_tvalid     <= 1'b0;
      if (m_axis_phase_tready) m_axis_phase_tvalid <= 1'b0;

      case (cordic_state)
        // 1. Idle / output phase: hold the result until every channel has
        //    been accepted; capture a new input (and do micro-rotation 0)
        //    as soon as the core is free.
        IDLE, OUTPUT: begin
          if (in_fire) begin
            x_tdata_temp <= x_next;
            y_tdata_temp <= y_next;
            phase_tdata_temp <= phase_next;
            iteration <= ITER_ONE;
            cordic_state <= ROTATE;
          end else if (out_done) begin
            cordic_state <= IDLE;
          end
        end

        // 2. The Iteration Flow: one micro-rotation per clock (1 .. niter-1)
        ROTATE: begin
          x_tdata_temp <= x_next;
          y_tdata_temp <= y_next;
          phase_tdata_temp <= phase_next;

          if (iteration == LAST_ITER) begin
            // Data Presentation: register final values and raise tvalid
            m_axis_x_tdata <= x_out;
            m_axis_y_tdata <= y_out;
            m_axis_phase_tdata <= PHASE_EN ? phase_out : {phase_width{1'b0}};
            m_axis_x_tvalid <= 1'b1;
            m_axis_y_tvalid <= 1'b1;
            m_axis_phase_tvalid <= PHASE_EN;
            iteration <= 0;
            cordic_state <= OUTPUT;
          end else begin
            iteration <= iteration + 1'b1;
          end
        end

        default: cordic_state <= IDLE;
      endcase
    end
  end

endmodule
