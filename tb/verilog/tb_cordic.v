`timescale 1ns / 1ps

// =============================================================================
// Testbench: tb_cordic
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Tests the circular CORDIC module (rotation mode) with 8 angle test cases.
// Each case feeds x0 = 1/K (pre-scaled), y0 = 0, z0 = target_angle.
// Expected outputs: x_out ≈ cos(angle) * 2^15, y_out ≈ sin(angle) * 2^15.
//
// Fixed-Point Convention:
//   inout_width = 16 → Q1.15 (1.0 = 32768)
//   phase_width = 18 → pi = 2^17 = 131072
//
// CORDIC Gain K(16 iter) = 1.646760, so 1/K = 0.607253
// 1/K in Q1.15 = round(0.607253 * 32768) = 19898
// =============================================================================

module tb_cordic();

  // -------------------------------------------------------------------------
  // Parameters
  // -------------------------------------------------------------------------
  parameter inout_width       = 16;
  parameter phase_width       = 18;
  parameter cordic_niter      = 16;
  parameter cordic_niter_width = 4;

  // Tolerance for pass/fail checking (in fixed-point LSBs)
  // 50 LSBs ≈ 0.15% of full scale — tight enough to catch regressions
  parameter TOLERANCE = 50;

  // -------------------------------------------------------------------------
  // DUT signals
  // -------------------------------------------------------------------------
  reg aclk, resetn;

  reg  signed [inout_width-1:0]  s_axis_x_tdata;
  reg                            s_axis_x_tvalid;
  wire                           s_axis_x_tready;

  reg  signed [inout_width-1:0]  s_axis_y_tdata;
  reg                            s_axis_y_tvalid;
  wire                           s_axis_y_tready;

  reg  signed [phase_width-1:0]  s_axis_phase_tdata;
  reg                            s_axis_phase_tvalid;
  wire                           s_axis_phase_tready;

  wire [cordic_niter_width-1:0]  atan_lut_address;
  wire signed [phase_width-1:0]  atan_lut_data;

  wire signed [inout_width-1:0]  m_axis_x_tdata;
  wire                           m_axis_x_tvalid;
  reg                            m_axis_x_tready;

  wire signed [inout_width-1:0]  m_axis_y_tdata;
  wire                           m_axis_y_tvalid;
  reg                            m_axis_y_tready;

  wire signed [phase_width-1:0]  m_axis_phase_tdata;
  wire                           m_axis_phase_tvalid;
  reg                            m_axis_phase_tready;

  // -------------------------------------------------------------------------
  // Atan Look-Up Table — uses the atan_lut module (ROM)
  // -------------------------------------------------------------------------
  atan_lut #(
    .PHASE_WIDTH (phase_width),
    .N_ENTRIES   (cordic_niter),
    .ADDR_WIDTH  (cordic_niter_width)
  ) u_atan_lut (
    .address (atan_lut_address),
    .data    (atan_lut_data)
  );

  // -------------------------------------------------------------------------
  // DUT Instantiation
  // -------------------------------------------------------------------------
  cordic #(
    .inout_width(inout_width),
    .phase_width(phase_width),
    .cordic_niter(cordic_niter),
    .cordic_niter_width(cordic_niter_width)
  ) dut (
    .aclk(aclk),
    .resetn(resetn),

    .s_axis_x_tdata(s_axis_x_tdata),
    .s_axis_x_tvalid(s_axis_x_tvalid),
    .s_axis_x_tready(s_axis_x_tready),

    .s_axis_y_tdata(s_axis_y_tdata),
    .s_axis_y_tvalid(s_axis_y_tvalid),
    .s_axis_y_tready(s_axis_y_tready),

    .s_axis_phase_tdata(s_axis_phase_tdata),
    .s_axis_phase_tvalid(s_axis_phase_tvalid),
    .s_axis_phase_tready(s_axis_phase_tready),

    .atan_lut_address(atan_lut_address),
    .atan_lut_data(atan_lut_data),

    .m_axis_x_tdata(m_axis_x_tdata),
    .m_axis_x_tvalid(m_axis_x_tvalid),
    .m_axis_x_tready(m_axis_x_tready),

    .m_axis_y_tdata(m_axis_y_tdata),
    .m_axis_y_tvalid(m_axis_y_tvalid),
    .m_axis_y_tready(m_axis_y_tready),

    .m_axis_phase_tdata(m_axis_phase_tdata),
    .m_axis_phase_tvalid(m_axis_phase_tvalid),
    .m_axis_phase_tready(m_axis_phase_tready)
  );

  // -------------------------------------------------------------------------
  // Clock generation — 100 MHz (10 ns period)
  // -------------------------------------------------------------------------
  initial aclk = 0;
  always #5 aclk = ~aclk;

  // -------------------------------------------------------------------------
  // Waveform dump
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("tb/dump.vcd");
    $dumpvars(0, tb_cordic);
  end

  // -------------------------------------------------------------------------
  // Test infrastructure
  // -------------------------------------------------------------------------
  integer pass_count = 0;
  integer fail_count = 0;
  integer total_tests = 0;

  // Absolute-value function for error checking
  function signed [inout_width-1:0] abs_val;
    input signed [inout_width-1:0] val;
    abs_val = (val < 0) ? -val : val;
  endfunction

  // ----- Reusable test task -----
  // Drives one CORDIC rotation and checks the output against expected values.
  //   x_in:       Initial x-component (typically 1/K in fixed-point)
  //   y_in:       Initial y-component (typically 0)
  //   phase_in:   Target rotation angle in fixed-point
  //   x_expected: Expected cos(angle) * 2^15
  //   y_expected: Expected sin(angle) * 2^15
  //   test_name:  Descriptive label for display
  task run_test;
    input signed [inout_width-1:0]  x_in;
    input signed [inout_width-1:0]  y_in;
    input signed [phase_width-1:0]  phase_in;
    input signed [inout_width-1:0]  x_expected;
    input signed [inout_width-1:0]  y_expected;
    input [255:0] test_name; // string
    reg signed [inout_width-1:0] x_err, y_err;
    begin
      total_tests = total_tests + 1;

      // --- Drive inputs ---
      @(posedge aclk);
      s_axis_x_tdata     = x_in;
      s_axis_y_tdata     = y_in;
      s_axis_phase_tdata = phase_in;
      s_axis_x_tvalid     = 1'b1;
      s_axis_y_tvalid     = 1'b1;
      s_axis_phase_tvalid = 1'b1;

      // --- Wait for slave handshake (data accepted) ---
      @(posedge aclk);
      wait(s_axis_x_tready && s_axis_x_tvalid);
      @(posedge aclk);

      // --- De-assert valid after handshake ---
      s_axis_x_tvalid     = 1'b0;
      s_axis_y_tvalid     = 1'b0;
      s_axis_phase_tvalid = 1'b0;

      // --- Wait for output valid ---
      wait(m_axis_x_tvalid);
      @(posedge aclk);

      // --- Check results ---
      x_err = abs_val(m_axis_x_tdata - x_expected);
      y_err = abs_val(m_axis_y_tdata - y_expected);

      $display("------------------------------------------------------------");
      $display("  Test: %0s", test_name);
      $display("  Input : x=%6d, y=%6d, phase=%7d", x_in, y_in, phase_in);
      $display("  Output: x=%6d, y=%6d (phase_rem=%7d)", m_axis_x_tdata, m_axis_y_tdata, m_axis_phase_tdata);
      $display("  Expect: x=%6d, y=%6d", x_expected, y_expected);
      $display("  Error : x=%6d, y=%6d (tolerance=%0d)", x_err, y_err, TOLERANCE);

      if (x_err <= TOLERANCE && y_err <= TOLERANCE) begin
        $display("  Result: PASS");
        pass_count = pass_count + 1;
      end else begin
        $display("  Result: *** FAIL ***");
        fail_count = fail_count + 1;
      end

      // Let the master handshake complete (DUT returns to IDLE)
      @(posedge aclk);
      @(posedge aclk);
    end
  endtask

  // -------------------------------------------------------------------------
  // Main test sequence
  // -------------------------------------------------------------------------
  //
  // Rotation Mode Setup:
  //   x0 = 1/K ≈ 19898  (so output is directly cos/sin * 2^15)
  //   y0 = 0
  //   z0 = target angle  (fixed-point, pi = 2^17 = 131072)
  //
  // -------------------------------------------------------------------------
  localparam signed [inout_width-1:0] INV_K = 16'sd19898;  // 1/K in Q1.15

  initial begin
    // Initialize
    resetn = 0;
    s_axis_x_tdata     = 0;
    s_axis_y_tdata     = 0;
    s_axis_phase_tdata = 0;
    s_axis_x_tvalid     = 0;
    s_axis_y_tvalid     = 0;
    s_axis_phase_tvalid = 0;
    m_axis_x_tready     = 1;
    m_axis_y_tready     = 1;
    m_axis_phase_tready = 1;

    // Reset
    #20 resetn = 1;
    #10;

    $display("============================================================");
    $display("  CORDIC Circular Rotation Mode Testbench");
    $display("  inout_width=%0d, phase_width=%0d, iterations=%0d",
             inout_width, phase_width, cordic_niter);
    $display("  Fixed-point: 1.0 = 2^15 = 32768, pi = 2^17 = 131072");
    $display("  1/K = %0d (pre-scaled input)", INV_K);
    $display("============================================================");

    // -----------------------------------------------------------------
    // Test 1: 10° rotation
    // cos(10) = 0.9848 → 32270,  sin(10) = 0.1736 → 5690
    // Phase = round(10/180 * 2^17) = 7282
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, 18'sd7282,
             16'sd32270, 16'sd5690,
             "Rotate 10 deg");

    // -----------------------------------------------------------------
    // Test 2: 15° rotation
    // cos(15) = 0.9659 → 31651, sin(15) = 0.2588 → 8481
    // Phase = round(15/180 * 2^17) = 10923
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, 18'sd10923,
             16'sd31651, 16'sd8481,
             "Rotate 15 deg");

    // -----------------------------------------------------------------
    // Test 3: 30° rotation
    // cos(30) = 0.8660 → 28378,  sin(30) = 0.5000 → 16384
    // Phase = 21845  (30/180 * 2^17)
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, 18'sd21845,
             16'sd28378, 16'sd16384,
             "Rotate 30 deg");

    // -----------------------------------------------------------------
    // Test 4: 45° rotation
    // cos(45) = 0.7071 → 23170,  sin(45) = 0.7071 → 23170
    // Phase = 32768  (45/180 * 2^17)
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, 18'sd32768,
             16'sd23170, 16'sd23170,
             "Rotate 45 deg");

    // -----------------------------------------------------------------
    // Test 5: 60° rotation
    // cos(60) = 0.5000 → 16384,  sin(60) = 0.8660 → 28378
    // Phase = round(60/180 * 2^17) = 43691
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, 18'sd43691,
             16'sd16384, 16'sd28378,
             "Rotate 60 deg");

    // -----------------------------------------------------------------
    // Test 6: 75° rotation
    // cos(75) = 0.2588 → 8481, sin(75) = 0.9659 → 31651
    // Phase = round(75/180 * 2^17) = 54613
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, 18'sd54613,
             16'sd8481, 16'sd31651,
             "Rotate 75 deg");

    // -----------------------------------------------------------------
    // Test 7: −45° rotation (counter-clockwise check)
    // cos(-45) = 0.7071 → 23170,  sin(-45) = -0.7071 → -23170
    // Phase = -32768
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, -18'sd32768,
             16'sd23170, -16'sd23170,
             "Rotate -45 deg");

    // -----------------------------------------------------------------
    // Test 8: −60° rotation
    // cos(-60) = 0.5000 → 16384, sin(-60) = -0.8660 → -28378
    // Phase = -43691
    // -----------------------------------------------------------------
    run_test(INV_K, 16'sd0, -18'sd43691,
             16'sd16384, -16'sd28378,
             "Rotate -60 deg");

    // -----------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------
    $display("============================================================");
    $display("  SUMMARY: %0d / %0d tests passed", pass_count, total_tests);
    if (fail_count > 0)
      $display("  *** %0d TEST(S) FAILED ***", fail_count);
    else
      $display("  ALL TESTS PASSED");
    $display("============================================================");

    #50 $finish;
  end

endmodule
