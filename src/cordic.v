// =============================================================================
// cordic — iterative circular CORDIC, rotation mode
// Author: Gabriel Galeote Checa, 2026 — License: MIT
// =============================================================================
// Rotates (x0, y0) by z0, one micro-rotation per clock:
//   x = K·(x0·cos z0 − y0·sin z0),  y = K·(y0·cos z0 + x0·sin z0),  K ≈ 1.6468
// Pre-scale the input by 1/K (19898 in Q1.15) to get cos/sin directly.
//
// Formats (defaults): x, y in Q1.15; phase with π = 2^17, any value in [−π, π).
// The atan LUT must be generated at phase_width + phase_guard_bits bits.
//
// AXI4-Stream: the x/y/phase inputs are accepted together; each output channel
// handshakes on its own. The phase output is the residual angle (≈ 0); set
// phase_output = 0 to disable it. Latency and throughput: cordic_niter cycles.
// =============================================================================

`timescale 1ns / 1ps

module cordic #(
  parameter inout_width        = 16,
  parameter phase_width        = 18,
  parameter cordic_niter       = 16,
  parameter cordic_niter_width = 4,
  parameter guard_bits         = 4,   // extra fractional bits on x/y (>= 1)
  parameter phase_guard_bits   = 4,   // extra fractional bits on the phase
  parameter phase_output       = 1    // 0: residual-phase output disabled
)(
  input aclk,
  input resetn,

  input signed [inout_width-1:0] s_axis_x_tdata,
  input s_axis_x_tvalid,
  output s_axis_x_tready,

  input signed [inout_width-1:0] s_axis_y_tdata,
  input s_axis_y_tvalid,
  output s_axis_y_tready,

  input signed [phase_width-1:0] s_axis_phase_tdata,
  input s_axis_phase_tvalid,
  output s_axis_phase_tready,

  output [cordic_niter_width-1:0] atan_lut_address,
  input signed [phase_width+phase_guard_bits-1:0] atan_lut_data,

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

  // Invalid parameters abort elaboration (undefined module).
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

  // x/y carry 2 extra integer bits for the gain growth (K·√2 < 4).
  localparam IW  = inout_width + 2 + guard_bits;
  localparam PIW = phase_width + phase_guard_bits;

  localparam integer                  LAST_ITER_INT = cordic_niter - 1;
  localparam [cordic_niter_width-1:0] LAST_ITER     = LAST_ITER_INT[cordic_niter_width-1:0];
  localparam integer                  ONE_INT       = 1;
  localparam [cordic_niter_width-1:0] ITER_ONE      = ONE_INT[cordic_niter_width-1:0];

  localparam [0:0] PHASE_EN = (phase_output != 0) ? 1'b1 : 1'b0;

  localparam [1:0] IDLE   = 2'd0;
  localparam [1:0] ROTATE = 2'd1;
  localparam [1:0] OUTPUT = 2'd2;

  reg [1:0] cordic_state;
  reg [cordic_niter_width-1:0] iteration;   // 0 outside ROTATE

  reg signed [IW-1:0]  x_tdata_temp;
  reg signed [IW-1:0]  y_tdata_temp;
  reg signed [PIW-1:0] phase_tdata_temp;

  // ── Handshakes ──
  wire x_pending     = m_axis_x_tvalid     && !m_axis_x_tready;
  wire y_pending     = m_axis_y_tvalid     && !m_axis_y_tready;
  wire phase_pending = m_axis_phase_tvalid && !m_axis_phase_tready;
  wire out_done      = !x_pending && !y_pending && !phase_pending;

  // A new input is taken while idle, or in the cycle the last output beat is
  // accepted, so s_axis_*_tready depends combinationally on m_axis_*_tready.
  wire not_busy     = (cordic_state == IDLE) || (cordic_state == OUTPUT);
  wire all_in_valid = s_axis_x_tvalid && s_axis_y_tvalid && s_axis_phase_tvalid;
  wire in_fire      = not_busy && out_done && all_in_valid;

  assign s_axis_x_tready     = in_fire;
  assign s_axis_y_tready     = in_fire;
  assign s_axis_phase_tready = in_fire;
  assign atan_lut_address    = iteration;

  // ── Input: sign-extend, add guard bits, fold the outer quadrants ──
  wire signed [IW-1:0] x_in_ext = {{2{s_axis_x_tdata[inout_width-1]}}, s_axis_x_tdata, {guard_bits{1'b0}}};
  wire signed [IW-1:0] y_in_ext = {{2{s_axis_y_tdata[inout_width-1]}}, s_axis_y_tdata, {guard_bits{1'b0}}};

  /* verilator lint_off WIDTHEXPAND */
  wire signed [PIW-1:0] z_in_wide = s_axis_phase_tdata;
  /* verilator lint_on WIDTHEXPAND */
  wire signed [PIW-1:0] z_in_ext  = z_in_wide <<< phase_guard_bits;

  // CORDIC only converges for |z| < ~99.9°. For |z| >= 90° (the two phase
  // MSBs differ) rotate by π first: (x, y, z) → (−x, −y, z ∓ π), where ∓π is
  // an MSB flip.
  wire quadrant_fold = z_in_ext[PIW-1] ^ z_in_ext[PIW-2];

  wire signed [IW-1:0]  x_in_fold = quadrant_fold ? -x_in_ext : x_in_ext;
  wire signed [IW-1:0]  y_in_fold = quadrant_fold ? -y_in_ext : y_in_ext;
  wire signed [PIW-1:0] z_in_fold = quadrant_fold ? {~z_in_ext[PIW-1], z_in_ext[PIW-2:0]} : z_in_ext;

  // ── Micro-rotation ──
  // Outside ROTATE the datapath works on the folded input with iteration = 0,
  // so micro-rotation 0 happens in the input-handshake cycle.
  wire start = (cordic_state != ROTATE);

  wire signed [IW-1:0]  x_cur = start ? x_in_fold : x_tdata_temp;
  wire signed [IW-1:0]  y_cur = start ? y_in_fold : y_tdata_temp;
  wire signed [PIW-1:0] z_cur = start ? z_in_fold : phase_tdata_temp;

  wire phase_neg = z_cur[PIW-1];

  wire signed [IW-1:0] x_shifted = x_cur >>> iteration;
  wire signed [IW-1:0] y_shifted = y_cur >>> iteration;

  wire signed [IW-1:0]  x_next     = phase_neg ? (x_cur + y_shifted) : (x_cur - y_shifted);
  wire signed [IW-1:0]  y_next     = phase_neg ? (y_cur - x_shifted) : (y_cur + x_shifted);
  wire signed [PIW-1:0] phase_next = phase_neg ? (z_cur + atan_lut_data) : (z_cur - atan_lut_data);

  // ── Output: round to nearest, drop the guard bits, saturate ──
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

  // The last micro-rotation is recomputed from the registers alone (the shift
  // by LAST_ITER is wiring). It equals x/y/phase_next in that cycle, but keeps
  // the input fold and capture mux out of the output timing path.
  wire phase_neg_last = phase_tdata_temp[PIW-1];

  wire signed [IW-1:0]  x_shifted_last = x_tdata_temp >>> LAST_ITER_INT;
  wire signed [IW-1:0]  y_shifted_last = y_tdata_temp >>> LAST_ITER_INT;

  wire signed [IW-1:0]  x_last     = phase_neg_last ? (x_tdata_temp + y_shifted_last)
                                                    : (x_tdata_temp - y_shifted_last);
  wire signed [IW-1:0]  y_last     = phase_neg_last ? (y_tdata_temp - x_shifted_last)
                                                    : (y_tdata_temp + x_shifted_last);
  /* verilator lint_off UNUSEDSIGNAL */
  wire signed [PIW-1:0] phase_last = phase_neg_last ? (phase_tdata_temp + atan_lut_data)
                                                    : (phase_tdata_temp - atan_lut_data);
  /* verilator lint_on UNUSEDSIGNAL */

  wire signed [inout_width-1:0] x_out     = round_sat(x_last);
  wire signed [inout_width-1:0] y_out     = round_sat(y_last);
  wire signed [phase_width-1:0] phase_out = phase_last[PIW-1:phase_guard_bits];

  // ── FSM ──
  always @(posedge aclk) begin
    if (!resetn) begin
      cordic_state <= IDLE;
      m_axis_x_tvalid <= 1'b0;
      m_axis_y_tvalid <= 1'b0;
      m_axis_phase_tvalid <= 1'b0;
      m_axis_x_tdata <= 0;
      m_axis_y_tdata <= 0;
      m_axis_phase_tdata <= 0;
      x_tdata_temp <= 0;
      y_tdata_temp <= 0;
      phase_tdata_temp <= 0;
      iteration <= 0;
    end else begin
      // Drop tvalid once accepted (overridden below by a new result)
      if (m_axis_x_tready)     m_axis_x_tvalid     <= 1'b0;
      if (m_axis_y_tready)     m_axis_y_tvalid     <= 1'b0;
      if (m_axis_phase_tready) m_axis_phase_tvalid <= 1'b0;

      case (cordic_state)
        // Hold the result until every channel is accepted; capture the next
        // input (and do micro-rotation 0) as soon as the core is free.
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

        // Micro-rotations 1 .. cordic_niter-1
        ROTATE: begin
          x_tdata_temp <= x_next;
          y_tdata_temp <= y_next;
          phase_tdata_temp <= phase_next;

          if (iteration == LAST_ITER) begin
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
