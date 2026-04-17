`timescale 1ns / 1ps

// =============================================================================
// Testbench: tb_cordic_sqrt
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Verifies the hyperbolic CORDIC square root module.
//
// For input value a, the module computes:
//   x0 = a + 1/4,  y0 = a - 1/4,  z0 = 0
//   → x_out ≈ K_h · √a    (K_h ≈ 0.8282)
//   → y_out ≈ 0
//
// Fixed-Point: Q1.15 (1.0 = 32768),  Phase: Q1.17 (1.0 = 131072)
// Input range: a ∈ (0, 0.75) in Q1.15
// =============================================================================

module tb_cordic_sqrt;

  // ── Parameters ──
  parameter data_width   = 16;
  parameter phase_width  = 18;
  parameter n_iterations = 16;
  parameter iter_width   = 4;

  // Tolerance for pass/fail checking (in fixed-point LSBs)
  // 50 LSBs ≈ 0.15% of full scale
  parameter TOLERANCE = 50;

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
    .N_ENTRIES   (14),
    .ADDR_WIDTH  (iter_width)
  ) u_atanh_lut (
    .address (lut_address),
    .data    (elementary_angle)
  );

  // ── DUT Instantiation ──
  cordic_sqrt_optimized #(
    .data_width   (data_width),
    .phase_width  (phase_width),
    .n_iterations (n_iterations),
    .iter_width   (iter_width)
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
  integer pass_count;
  integer test_count;

  // Quarter in Q1.15 (0.25 * 32768 = 8192)
  localparam signed [data_width-1:0] QUARTER = 16'sd8192;

  task run_sqrt_test;
    input signed [data_width-1:0] a_fixed;      // input value in Q1.15
    input signed [data_width-1:0] x_expected;    // K_h * sqrt(a) in Q1.15
    input [255:0] test_name;
  begin
    test_count = test_count + 1;

    // Compute x0 = a + 1/4,  y0 = a - 1/4,  z0 = 0
    @(posedge clk);
    x_initial   <= a_fixed + QUARTER;
    y_initial   <= a_fixed - QUARTER;
    z_initial   <= 0;
    input_valid <= 1'b1;

    // Wait for handshake
    @(posedge clk);
    while (!(input_valid && input_ready)) @(posedge clk);
    @(posedge clk);
    input_valid <= 1'b0;

    // Wait for output
    while (!output_valid) @(posedge clk);
    @(posedge clk);

    // Calculate error
    begin : error_check
      integer x_err, y_abs;
      x_err = (x_final > x_expected) ? (x_final - x_expected) : (x_expected - x_final);
      y_abs = (y_final < 0) ? -y_final : y_final;

      $display("------------------------------------------------------------");
      $display("  Test: %0s", test_name);
      $display("  Input : a_fixed=%0d  →  x0=%0d, y0=%0d, z0=%0d",
               a_fixed, a_fixed + QUARTER, a_fixed - QUARTER, 0);
      $display("  Output: x=%0d (K_h·√a), y=%0d (≈0), z=%0d",
               x_final, y_final, z_final);
      $display("  Expect: x=%0d", x_expected);
      $display("  Error : x=%0d, |y|=%0d (tolerance=%0d)", x_err, y_abs, TOLERANCE);

      if (x_err <= TOLERANCE) begin
        $display("  Result: PASS");
        pass_count = pass_count + 1;
      end else begin
        $display("  Result: *** FAIL ***");
      end
    end

    // Let DUT return to IDLE
    @(posedge clk);
    @(posedge clk);
  end
  endtask

  // ── Main test sequence ──
  initial begin
    pass_count = 0;
    test_count = 0;

    // Reset
    resetn       = 0;
    input_valid  = 0;
    output_ready = 1;
    x_initial    = 0;
    y_initial    = 0;
    z_initial    = 0;
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (2) @(posedge clk);

    $display("============================================================");
    $display("  CORDIC Hyperbolic Vectoring — Square Root Testbench");
    $display("  data_width=%0d, phase_width=%0d, iterations=%0d",
             data_width, phase_width, n_iterations);
    $display("  Fixed-point: 1.0 = 2^15 = 32768");
    $display("  K_h ≈ 0.8282 (hyperbolic CORDIC gain)");
    $display("  Input range: a ∈ (0, 0.75) in Q1.15");
    $display("============================================================");

    // -----------------------------------------------------------------
    // Test 1: sqrt(0.125)
    // a = 0.125 * 32768 = 4096
    // Expected: K_h * sqrt(0.125) = 0.8282 * 0.3536 = 0.2928 → 9594
    // -----------------------------------------------------------------
    run_sqrt_test(16'sd4096, 16'sd9594, "sqrt(0.125)");

    // -----------------------------------------------------------------
    // Test 2: sqrt(0.25)
    // a = 0.25 * 32768 = 8192
    // Expected: K_h * sqrt(0.25) = 0.8282 * 0.5 = 0.4141 → 13569
    // -----------------------------------------------------------------
    run_sqrt_test(16'sd8192, 16'sd13569, "sqrt(0.25)");

    // -----------------------------------------------------------------
    // Test 3: sqrt(0.5)
    // a = 0.5 * 32768 = 16384
    // Expected: K_h * sqrt(0.5) = 0.8282 * 0.7071 = 0.5856 → 19189
    // -----------------------------------------------------------------
    run_sqrt_test(16'sd16384, 16'sd19189, "sqrt(0.5)");

    // -----------------------------------------------------------------
    // Test 4: sqrt(0.0625)
    // a = 0.0625 * 32768 = 2048
    // Expected: K_h * sqrt(0.0625) = 0.8282 * 0.25 = 0.2070 → 6784
    // -----------------------------------------------------------------
    run_sqrt_test(16'sd2048, 16'sd6784, "sqrt(0.0625)");

    // -----------------------------------------------------------------
    // Test 5: sqrt(0.375)
    // a = 0.375 * 32768 = 12288
    // Expected: K_h * sqrt(0.375) = 0.8282 * 0.6124 = 0.5072 → 16620
    // -----------------------------------------------------------------
    run_sqrt_test(16'sd12288, 16'sd16620, "sqrt(0.375)");

    // -----------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------
    $display("============================================================");
    $display("  SUMMARY: %0d / %0d tests passed", pass_count, test_count);
    if (pass_count == test_count)
      $display("  ALL TESTS PASSED");
    else
      $display("  SOME TESTS FAILED");
    $display("============================================================");

    $finish;
  end

endmodule
