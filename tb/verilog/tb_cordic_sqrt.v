`timescale 1ns / 1ps

// =============================================================================
// Testbench: tb_cordic_sqrt
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Self-checking testbench for the hyperbolic CORDIC square root core.
//
// For input value a, the module computes:
//   x0 = a + 1/4,  y0 = a - 1/4,  z0 = 0
//   → x_out ≈ K_h · √a          (K_h ≈ 0.8282)
//   → y_out ≈ 0
//   → z_out ≈ atanh(y0 / x0)    (Q2.(phase_width-2))
//
// Expected values use K_h computed from the same iteration sequence as the
// RTL (j(i) = i + 1 − [i >= 4] − [i >= 14], i = 0 .. n_iterations-1).
//
// Test vectors: the 5 original reference points plus a sweep of
// a ∈ [0.03, 0.74]. The set is run twice: back-to-back with output_ready
// always high, then with random input gaps and random output back-pressure.
// A monitor checks that the output stays stable while stalled and that
// exactly one result is produced per input.
//
// Fixed-Point (defaults): Q1.15 (1.0 = 32768),  Phase: Q2.16 (1.0 = 65536)
// Input range: a ∈ (0.03, 0.75)
//
// All parameters can be overridden from the command line, e.g.
//   iverilog -Ptb_cordic_sqrt.data_width=24 -Ptb_cordic_sqrt.n_iterations=22 ...
//
// Exits with $fatal on any failure so it can be used in CI.
// =============================================================================

module tb_cordic_sqrt;

  // ── Parameters ──
  parameter data_width   = 16;
  parameter phase_width  = 18;
  parameter n_iterations = 16;
  parameter iter_width   = 4;
  parameter guard_bits   = 2;

  // Tolerance for pass/fail checking (in fixed-point LSBs)
  parameter TOLERANCE   = 3;
  parameter Y_TOLERANCE = 2;
  parameter Z_TOLERANCE = 32;   // z LSB = 2^-(phase_width-2)

  // atanh LUT size: j_max of the iteration sequence
  localparam LUT_ENTRIES = n_iterations - ((n_iterations >= 5) ? 1 : 0)
                                        - ((n_iterations >= 15) ? 1 : 0);

  localparam MAX_VECTORS = 128;

  // ── DUT signals ──
  reg                             clk;
  reg                             resetn;

  reg  signed [data_width-1:0]    x_initial;
  reg  signed [data_width-1:0]    y_initial;
  reg  signed [phase_width-1:0]   z_initial;
  reg                             input_valid;
  wire                            input_ready;

  wire [iter_width-1:0]           lut_address;
  wire signed [phase_width-1:0]   elementary_angle;

  wire signed [data_width-1:0]    x_final;
  wire signed [data_width-1:0]    y_final;
  wire signed [phase_width-1:0]   z_final;
  wire                            output_valid;
  reg                             output_ready;

  // ── Atanh LUT (ROM) ──
  atanh_lut #(
    .PHASE_WIDTH (phase_width),
    .N_ENTRIES   (LUT_ENTRIES),
    .ADDR_WIDTH  (iter_width)
  ) u_atanh_lut (
    .address (lut_address),
    .data    (elementary_angle)
  );

  // ── DUT Instantiation ──
  cordic_sqrt #(
    .data_width   (data_width),
    .phase_width  (phase_width),
    .n_iterations (n_iterations),
    .iter_width   (iter_width),
    .guard_bits   (guard_bits)
  ) dut (
    .aclk              (clk),
    .resetn            (resetn),
    .x_initial         (x_initial),
    .y_initial         (y_initial),
    .z_initial         (z_initial),
    .input_valid       (input_valid),
    .input_ready       (input_ready),
    .lut_address       (lut_address),
    .elementary_angle  (elementary_angle),
    .x_final           (x_final),
    .y_final           (y_final),
    .z_final           (z_final),
    .output_valid      (output_valid),
    .output_ready      (output_ready)
  );

  // ── Clock generation — 100 MHz ──
  initial clk = 0;
  always #5 clk = ~clk;

  // ── Waveform dump ──
  initial begin
    $dumpfile("tb/dump_sqrt.vcd");
    $dumpvars(0, tb_cordic_sqrt);
  end

  // ── Test infrastructure ──
  integer vec_a  [0:MAX_VECTORS-1];
  integer exp_x  [0:MAX_VECTORS-1];
  integer exp_z  [0:MAX_VECTORS-1];
  integer n_vectors;

  integer error_count;
  integer max_x_err, max_y_abs, max_z_err;
  integer seed;
  reg     backpressure;
  real    k_h;

  // 1.0 and 0.25 in Q1.(data_width-1); 1.0 of the Q2.(phase_width-2) phase
  localparam integer ONE     = 1 << (data_width-1);
  localparam integer QUARTER = ONE / 4;
  localparam real    ONE_R   = 2.0 ** (data_width-1);
  localparam real    Z_ONE_R = 2.0 ** (phase_width-2);

  function integer iabs;
    input integer v;
    iabs = (v < 0) ? -v : v;
  endfunction

  function integer rnd;   // round to nearest, ties away from zero
    input real v;
    rnd = (v >= 0.0) ? $rtoi(v + 0.5) : -$rtoi(-v + 0.5);
  endfunction

  task add_vector;
    input integer a_fixed;     // input value in Q1.(data_width-1)
    begin
      vec_a[n_vectors] = a_fixed;
      exp_x[n_vectors] = rnd(k_h * $sqrt(a_fixed / ONE_R) * ONE_R);
      exp_z[n_vectors] = rnd($atanh((a_fixed - QUARTER) * 1.0 / (a_fixed + QUARTER)) * Z_ONE_R);
      n_vectors = n_vectors + 1;
    end
  endtask

  // Add a vector given as a real value a
  task add_real;
    input real a;
    add_vector(rnd(a * ONE_R));
  endtask

  // ── Output ready generator ──
  always @(posedge clk)
    output_ready <= backpressure ? (($random(seed) & 3) != 0) : 1'b1;

  // ── Monitor / scoreboard ──
  integer beats;
  reg                          prev_stall;
  reg signed [data_width-1:0]  prev_x, prev_y;
  reg signed [phase_width-1:0] prev_z;

  always @(posedge clk) begin
    if (!resetn) begin
      prev_stall <= 1'b0;
    end else begin
      if (prev_stall && (!output_valid || x_final !== prev_x ||
                         y_final !== prev_y || z_final !== prev_z)) begin
        $display("  *** PROTOCOL ERROR @%0t: output changed while stalled", $time);
        error_count = error_count + 1;
      end
      prev_stall <= output_valid && !output_ready;
      prev_x     <= x_final;
      prev_y     <= y_final;
      prev_z     <= z_final;

      if (output_valid && output_ready) begin
        if (beats >= n_vectors) begin
          $display("  *** ERROR @%0t: unexpected extra output", $time);
          error_count = error_count + 1;
        end else begin
          if (iabs(x_final - exp_x[beats]) > max_x_err) max_x_err = iabs(x_final - exp_x[beats]);
          if (iabs(y_final) > max_y_abs) max_y_abs = iabs(y_final);
          if (iabs(z_final - exp_z[beats]) > max_z_err) max_z_err = iabs(z_final - exp_z[beats]);
          if (iabs(x_final - exp_x[beats]) > TOLERANCE || iabs(y_final) > Y_TOLERANCE ||
              iabs(z_final - exp_z[beats]) > Z_TOLERANCE) begin
            $display("  *** FAIL a=%0d (%f): x=%0d expected %0d, y=%0d, z=%0d expected %0d",
                     vec_a[beats], vec_a[beats] / ONE_R, x_final, exp_x[beats], y_final,
                     z_final, exp_z[beats]);
            error_count = error_count + 1;
          end
        end
        beats = beats + 1;
      end
    end
  end

  // ── Stimulus driver ──
  task run_pass;
    input pass_backpressure;
    integer i, timeout;
    begin
      backpressure = pass_backpressure;
      beats = 0;
      for (i = 0; i < n_vectors; i = i + 1) begin
        if (backpressure)
          while (($random(seed) & 3) == 0) @(posedge clk);

        // Compute x0 = a + 1/4,  y0 = a - 1/4,  z0 = 0
        x_initial   <= vec_a[i] + QUARTER;
        y_initial   <= vec_a[i] - QUARTER;
        z_initial   <= 0;
        input_valid <= 1'b1;

        @(posedge clk);
        while (!(input_valid && input_ready)) @(posedge clk);
        input_valid <= 1'b0;
      end

      timeout = 0;
      while (beats < n_vectors && timeout < 1000) begin
        @(posedge clk);
        timeout = timeout + 1;
      end
      if (timeout >= 1000) begin
        $display("  *** ERROR: timeout waiting for outputs (%0d of %0d)", beats, n_vectors);
        error_count = error_count + 1;
      end
      repeat (n_iterations + 8) @(posedge clk);
    end
  endtask

  // ── Main test sequence ──
  integer i;

  initial begin
    seed = 32'h0005_0127;
    error_count = 0;
    max_x_err = 0;
    max_y_abs = 0;
    max_z_err = 0;
    n_vectors = 0;
    backpressure = 1'b0;

    // Hyperbolic gain for the RTL iteration sequence
    k_h = 1.0;
    for (i = 0; i < n_iterations; i = i + 1)
      k_h = k_h * $sqrt(1.0 - 2.0 ** (-2 * (i + 1 - ((i >= 4) ? 1 : 0) - ((i >= 14) ? 1 : 0))));

    // Original reference points: 0.125, 0.25, 0.5, 0.0625, 0.375
    add_real(0.125);
    add_real(0.25);
    add_real(0.5);
    add_real(0.0625);
    add_real(0.375);
    // Sweep a ∈ [0.03, 0.74] (0.03 itself is just below the range; start a hair above)
    add_real(0.0301);
    for (i = 4; i <= 74; i = i + 1)
      add_real(i / 100.0);
    // Random points inside the range
    for (i = 0; i < 40; i = i + 1)
      add_real((1000 + ({$random(seed)} % 23500)) / 32768.0);

    // Reset
    resetn       = 0;
    input_valid  = 0;
    output_ready = 1;
    x_initial    = 0;
    y_initial    = 0;
    z_initial    = 0;
    repeat (4) @(posedge clk);
    resetn <= 1;
    repeat (2) @(posedge clk);

    $display("============================================================");
    $display("  CORDIC Hyperbolic Vectoring — Square Root Testbench");
    $display("  data_width=%0d, phase_width=%0d, iterations=%0d",
             data_width, phase_width, n_iterations);
    $display("  guard_bits=%0d, atanh LUT entries=%0d", guard_bits, LUT_ENTRIES);
    $display("  Fixed-point: 1.0 = 2^%0d, phase 1.0 = 2^%0d", data_width-1, phase_width-2);
    $display("  K_h = %f (hyperbolic CORDIC gain)", k_h);
    $display("  Vectors: %0d, tolerance: %0d LSB", n_vectors, TOLERANCE);
    $display("============================================================");

    $display("  Pass 0: back-to-back, no back-pressure");
    run_pass(1'b0);
    $display("  Pass 1: random input gaps and output back-pressure");
    run_pass(1'b1);

    // -----------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------
    $display("============================================================");
    $display("  Max error: x=%0d LSB, |y|=%0d LSB, z=%0d LSB", max_x_err, max_y_abs, max_z_err);
    if (error_count > 0) begin
      $display("  *** %0d ERROR(S) ***", error_count);
      $display("============================================================");
      $fatal(1, "tb_cordic_sqrt FAILED");
    end
    $display("  ALL TESTS PASSED (%0d vectors x 2 passes)", n_vectors);
    $display("============================================================");

    $finish;
  end

endmodule
