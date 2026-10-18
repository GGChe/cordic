`timescale 1ns / 1ps

// =============================================================================
// Testbench: tb_cordic
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Self-checking testbench for the circular CORDIC (rotation mode).
//
// DUT selection:
//   default        → `cordic` core + `atan_lut` instantiated here
//   +define+TB_USE_TOP (iverilog -DTB_USE_TOP) → `cordic_top` wrapper
//
// Expected outputs are computed with real arithmetic:
//   x_out = K · (x0·cos(z0) − y0·sin(z0))
//   y_out = K · (y0·cos(z0) + x0·sin(z0))
// rounded and saturated to Q1.15.
//
// Test vectors:
//   1. The 8 original reference angles (x0 = 1/K, y0 = 0)
//   2. Edge angles: 0°, ±90°, −180°, ±179.9°, ±100°, 120°, 135°, 170°, −150°
//   3. Non-zero y0 and saturating inputs
//   4. Full-circle sweep in 3° steps
//   5. Random vectors (x0, y0, z0)
//
// Every vector set is run twice:
//   pass 0 — back-to-back inputs, tready always high (max throughput)
//   pass 1 — random tvalid gaps and independent random tready per channel
//
// A protocol monitor checks the AXI-Stream rules on every cycle:
//   - no slave channel is accepted unless all three are valid
//   - master tvalid/tdata stay stable while tvalid && !tready
//   - exactly one beat per channel per input (scoreboard by beat index)
//   - pass 0 sustains one result every cordic_niter cycles
//   - with phase_output = 0 the phase channel never raises tvalid
//
// All parameters can be overridden from the command line, e.g.
//   iverilog -Ptb_cordic.inout_width=12 -Ptb_cordic.phase_width=14 ...
// The Q1.15 test values are rescaled to inout_width.
//
// Fixed-Point Convention (defaults):
//   inout_width = 16 → Q1.15 (1.0 = 32768)
//   phase_width = 18 → pi = 2^17 = 131072
//
// Exits with $fatal on any failure so it can be used in CI.
// =============================================================================

module tb_cordic();

  // -------------------------------------------------------------------------
  // Parameters
  // -------------------------------------------------------------------------
  parameter inout_width       = 16;
  parameter phase_width       = 18;
  parameter cordic_niter      = 16;
  parameter cordic_niter_width = 4;
  parameter guard_bits         = 4;
  parameter phase_guard_bits   = 4;
  parameter phase_output       = 1;

  // Tolerance for pass/fail checking (in fixed-point LSBs)
  parameter TOLERANCE       = 2;
  parameter PHASE_TOLERANCE = 4;

  localparam CLK_PERIOD = 10;

  localparam MAX_VECTORS = 512;
  localparam real PI = 3.14159265358979323846;

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

  wire signed [inout_width-1:0]  m_axis_x_tdata;
  wire                           m_axis_x_tvalid;
  reg                            m_axis_x_tready;

  wire signed [inout_width-1:0]  m_axis_y_tdata;
  wire                           m_axis_y_tvalid;
  reg                            m_axis_y_tready;

  wire signed [phase_width-1:0]  m_axis_phase_tdata;
  wire                           m_axis_phase_tvalid;
  reg                            m_axis_phase_tready;

`ifdef TB_USE_TOP
  // -------------------------------------------------------------------------
  // DUT: top-level wrapper (core + LUT)
  // -------------------------------------------------------------------------
  cordic_top #(
    .INOUT_WIDTH       (inout_width),
    .PHASE_WIDTH       (phase_width),
    .CORDIC_NITER      (cordic_niter),
    .CORDIC_NITER_WIDTH(cordic_niter_width),
    .GUARD_BITS        (guard_bits),
    .PHASE_GUARD_BITS  (phase_guard_bits),
    .PHASE_OUTPUT      (phase_output)
  ) dut (
`else
  // -------------------------------------------------------------------------
  // Atan Look-Up Table — uses the atan_lut module (ROM), generated at the
  // core's internal phase width
  // -------------------------------------------------------------------------
  localparam LUT_WIDTH = phase_width + phase_guard_bits;

  wire [cordic_niter_width-1:0]  atan_lut_address;
  wire signed [LUT_WIDTH-1:0]    atan_lut_data;

  atan_lut #(
    .PHASE_WIDTH (LUT_WIDTH),
    .N_ENTRIES   (cordic_niter),
    .ADDR_WIDTH  (cordic_niter_width)
  ) u_atan_lut (
    .address (atan_lut_address),
    .data    (atan_lut_data)
  );

  // -------------------------------------------------------------------------
  // DUT: bare core
  // -------------------------------------------------------------------------
  cordic #(
    .inout_width(inout_width),
    .phase_width(phase_width),
    .cordic_niter(cordic_niter),
    .cordic_niter_width(cordic_niter_width),
    .guard_bits(guard_bits),
    .phase_guard_bits(phase_guard_bits),
    .phase_output(phase_output)
  ) dut (
    .atan_lut_address(atan_lut_address),
    .atan_lut_data(atan_lut_data),
`endif
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
  always #(CLK_PERIOD/2) aclk = ~aclk;

  // -------------------------------------------------------------------------
  // Waveform dump
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("tb/dump.vcd");
    $dumpvars(0, tb_cordic);
  end

  // -------------------------------------------------------------------------
  // Test vector storage
  // -------------------------------------------------------------------------
  integer vec_x   [0:MAX_VECTORS-1];
  integer vec_y   [0:MAX_VECTORS-1];
  integer vec_z   [0:MAX_VECTORS-1];
  integer exp_x   [0:MAX_VECTORS-1];
  integer exp_y   [0:MAX_VECTORS-1];
  integer n_vectors;

  real cordic_gain;
  integer inv_k;

  integer error_count;
  integer max_x_err, max_y_err, max_phase_err;
  integer seed;
  reg     backpressure;  // pass 1: random tvalid gaps / tready

  function integer iabs;
    input integer v;
    iabs = (v < 0) ? -v : v;
  endfunction

  // Rescale a Q1.15 test value to Q1.(inout_width-1)
  function integer q15;
    input integer v;
    begin
      if (inout_width >= 16) q15 = v * (1 << (inout_width-16));
      else                   q15 = v >>> (16-inout_width);
    end
  endfunction

  function integer saturate;
    input real v;
    integer r;
    begin
      r = (v >= 0.0) ? $rtoi(v + 0.5) : -$rtoi(-v + 0.5);
      if (r > (1 << (inout_width-1)) - 1) r = (1 << (inout_width-1)) - 1;
      if (r < -(1 << (inout_width-1)))    r = -(1 << (inout_width-1));
      saturate = r;
    end
  endfunction

  // Add one test vector with real-valued inputs (x, y in units of 1.0,
  // angle in degrees) and compute its expected output.
  task add_vector;
    input integer x_fixed;
    input integer y_fixed;
    input real    angle_deg;
    real    z_rad;
    integer z_fixed;
    begin
      z_fixed = $rtoi(angle_deg / 180.0 * (1 << (phase_width-1)) +
                      ((angle_deg >= 0.0) ? 0.5 : -0.5));
      // Wrap into [−π, π)
      if (z_fixed >= (1 << (phase_width-1)))  z_fixed = z_fixed - (1 << phase_width);
      if (z_fixed < -(1 << (phase_width-1)))  z_fixed = z_fixed + (1 << phase_width);
      z_rad = z_fixed * PI / (1 << (phase_width-1));

      vec_x[n_vectors] = x_fixed;
      vec_y[n_vectors] = y_fixed;
      vec_z[n_vectors] = z_fixed;
      exp_x[n_vectors] = saturate(cordic_gain * (x_fixed * $cos(z_rad) - y_fixed * $sin(z_rad)));
      exp_y[n_vectors] = saturate(cordic_gain * (y_fixed * $cos(z_rad) + x_fixed * $sin(z_rad)));
      n_vectors = n_vectors + 1;
    end
  endtask

  // -------------------------------------------------------------------------
  // Master-side ready generator (random back-pressure in pass 1)
  // -------------------------------------------------------------------------
  always @(posedge aclk) begin
    if (backpressure) begin
      m_axis_x_tready     <= ($random(seed) & 3) != 0;
      m_axis_y_tready     <= ($random(seed) & 3) != 0;
      m_axis_phase_tready <= ($random(seed) & 3) != 0;
    end else begin
      m_axis_x_tready     <= 1'b1;
      m_axis_y_tready     <= 1'b1;
      m_axis_phase_tready <= 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // Protocol monitor + scoreboard
  // -------------------------------------------------------------------------
  integer beats_x, beats_y, beats_phase;
  integer n_phase_expected;          // n_vectors, or 0 if phase_output = 0
  integer last_fire_time;            // time of the previous input handshake (−1: none)
  integer max_interval;              // longest input-to-input interval in pass 0 (cycles)

  reg                           prev_x_stall, prev_y_stall, prev_phase_stall;
  reg signed [inout_width-1:0]  prev_x_data, prev_y_data;
  reg signed [phase_width-1:0]  prev_phase_data;

  always @(posedge aclk) begin
    if (!resetn) begin
      prev_x_stall <= 1'b0;
      prev_y_stall <= 1'b0;
      prev_phase_stall <= 1'b0;
    end else begin
      // Throughput: in pass 0 a new input must be taken every cordic_niter cycles
      if (s_axis_x_tvalid && s_axis_x_tready) begin
        if (!backpressure && last_fire_time >= 0) begin
          if (($time - last_fire_time) / CLK_PERIOD > max_interval)
            max_interval = ($time - last_fire_time) / CLK_PERIOD;
        end
        last_fire_time = $time;
      end

      // Phase channel disabled: it must stay silent
      if (phase_output == 0 && m_axis_phase_tvalid) begin
        $display("  *** ERROR @%0t: phase tvalid raised with phase_output = 0", $time);
        error_count = error_count + 1;
      end

      // Slave side: a channel must never be accepted on its own
      if ((s_axis_x_tready || s_axis_y_tready || s_axis_phase_tready) &&
          !(s_axis_x_tvalid && s_axis_y_tvalid && s_axis_phase_tvalid &&
            s_axis_x_tready && s_axis_y_tready && s_axis_phase_tready)) begin
        $display("  *** PROTOCOL ERROR @%0t: slave tready without all channels valid/ready", $time);
        error_count = error_count + 1;
      end

      // Master side: stability while stalled
      if (prev_x_stall && (!m_axis_x_tvalid || m_axis_x_tdata !== prev_x_data)) begin
        $display("  *** PROTOCOL ERROR @%0t: x channel changed while stalled", $time);
        error_count = error_count + 1;
      end
      if (prev_y_stall && (!m_axis_y_tvalid || m_axis_y_tdata !== prev_y_data)) begin
        $display("  *** PROTOCOL ERROR @%0t: y channel changed while stalled", $time);
        error_count = error_count + 1;
      end
      if (prev_phase_stall && (!m_axis_phase_tvalid || m_axis_phase_tdata !== prev_phase_data)) begin
        $display("  *** PROTOCOL ERROR @%0t: phase channel changed while stalled", $time);
        error_count = error_count + 1;
      end
      prev_x_stall     <= m_axis_x_tvalid && !m_axis_x_tready;
      prev_y_stall     <= m_axis_y_tvalid && !m_axis_y_tready;
      prev_phase_stall <= m_axis_phase_tvalid && !m_axis_phase_tready;
      prev_x_data      <= m_axis_x_tdata;
      prev_y_data      <= m_axis_y_tdata;
      prev_phase_data  <= m_axis_phase_tdata;

      // Scoreboard: compare each beat against the vector with the same index
      if (m_axis_x_tvalid && m_axis_x_tready) begin
        if (beats_x >= n_vectors) begin
          $display("  *** ERROR @%0t: unexpected extra x beat", $time);
          error_count = error_count + 1;
        end else begin
          if (iabs(m_axis_x_tdata - exp_x[beats_x]) > max_x_err)
            max_x_err = iabs(m_axis_x_tdata - exp_x[beats_x]);
          if (iabs(m_axis_x_tdata - exp_x[beats_x]) > TOLERANCE) begin
            $display("  *** FAIL vector %0d: x=%0d y0=%0d z=%0d → x_out=%0d expected %0d",
                     beats_x, vec_x[beats_x], vec_y[beats_x], vec_z[beats_x],
                     m_axis_x_tdata, exp_x[beats_x]);
            error_count = error_count + 1;
          end
        end
        beats_x = beats_x + 1;
      end
      if (m_axis_y_tvalid && m_axis_y_tready) begin
        if (beats_y >= n_vectors) begin
          $display("  *** ERROR @%0t: unexpected extra y beat", $time);
          error_count = error_count + 1;
        end else begin
          if (iabs(m_axis_y_tdata - exp_y[beats_y]) > max_y_err)
            max_y_err = iabs(m_axis_y_tdata - exp_y[beats_y]);
          if (iabs(m_axis_y_tdata - exp_y[beats_y]) > TOLERANCE) begin
            $display("  *** FAIL vector %0d: x=%0d y0=%0d z=%0d → y_out=%0d expected %0d",
                     beats_y, vec_x[beats_y], vec_y[beats_y], vec_z[beats_y],
                     m_axis_y_tdata, exp_y[beats_y]);
            error_count = error_count + 1;
          end
        end
        beats_y = beats_y + 1;
      end
      if (m_axis_phase_tvalid && m_axis_phase_tready) begin
        if (beats_phase >= n_phase_expected) begin
          $display("  *** ERROR @%0t: unexpected extra phase beat", $time);
          error_count = error_count + 1;
        end else begin
          if (iabs(m_axis_phase_tdata) > max_phase_err)
            max_phase_err = iabs(m_axis_phase_tdata);
          if (iabs(m_axis_phase_tdata) > PHASE_TOLERANCE) begin
            $display("  *** FAIL vector %0d: residual phase %0d", beats_phase, m_axis_phase_tdata);
            error_count = error_count + 1;
          end
        end
        beats_phase = beats_phase + 1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Stimulus driver
  // -------------------------------------------------------------------------
  task run_pass;
    input pass_backpressure;
    integer i, timeout;
    begin
      backpressure = pass_backpressure;
      beats_x = 0;
      beats_y = 0;
      beats_phase = 0;
      last_fire_time = -1;

      for (i = 0; i < n_vectors; i = i + 1) begin
        // Optional idle gap before presenting the next input
        if (backpressure)
          while (($random(seed) & 3) == 0) @(posedge aclk);

        s_axis_x_tdata      <= vec_x[i];
        s_axis_y_tdata      <= vec_y[i];
        s_axis_phase_tdata  <= vec_z[i];
        s_axis_x_tvalid     <= 1'b1;
        s_axis_y_tvalid     <= 1'b1;
        s_axis_phase_tvalid <= 1'b1;

        // Wait for the handshake (tready is sampled at the clock edge)
        @(posedge aclk);
        while (!(s_axis_x_tvalid && s_axis_x_tready)) @(posedge aclk);

        s_axis_x_tvalid     <= 1'b0;
        s_axis_y_tvalid     <= 1'b0;
        s_axis_phase_tvalid <= 1'b0;
      end

      // Drain: wait for every output beat
      timeout = 0;
      while ((beats_x < n_vectors || beats_y < n_vectors || beats_phase < n_phase_expected) &&
             timeout < 1000) begin
        @(posedge aclk);
        timeout = timeout + 1;
      end
      if (timeout >= 1000) begin
        $display("  *** ERROR: timeout draining outputs (x=%0d y=%0d phase=%0d of %0d)",
                 beats_x, beats_y, beats_phase, n_vectors);
        error_count = error_count + 1;
      end
      // Watch for spurious extra beats
      repeat (cordic_niter + 8) @(posedge aclk);
    end
  endtask

  task partial_valid_check;
    begin
      // Only the x channel is valid: the DUT must not accept anything
      backpressure = 1'b0;
      @(posedge aclk);
      s_axis_x_tdata      <= q15(1234);
      s_axis_x_tvalid     <= 1'b1;
      s_axis_y_tvalid     <= 1'b0;
      s_axis_phase_tvalid <= 1'b0;
      repeat (10) @(posedge aclk);
      // y joins, phase still missing
      s_axis_y_tvalid     <= 1'b1;
      repeat (10) @(posedge aclk);
      s_axis_x_tvalid     <= 1'b0;
      s_axis_y_tvalid     <= 1'b0;
      @(posedge aclk);
      if (m_axis_x_tvalid || m_axis_y_tvalid || m_axis_phase_tvalid) begin
        $display("  *** ERROR: DUT started a computation on partial input");
        error_count = error_count + 1;
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // Main test sequence
  // -------------------------------------------------------------------------
  integer i;
  real    ang;

  initial begin
    seed = 32'h00C0_D1C0;
    error_count = 0;
    max_x_err = 0;
    max_y_err = 0;
    max_phase_err = 0;
    max_interval = 0;
    last_fire_time = -1;
    n_vectors = 0;
    backpressure = 1'b0;

    // CORDIC gain for this iteration count
    cordic_gain = 1.0;
    for (i = 0; i < cordic_niter; i = i + 1)
      cordic_gain = cordic_gain * $sqrt(1.0 + 2.0 ** (-2 * i));
    inv_k = $rtoi((1 << (inout_width-1)) / cordic_gain + 0.5);

    // 1. Original reference angles
    add_vector(inv_k, 0,  10.0);
    add_vector(inv_k, 0,  15.0);
    add_vector(inv_k, 0,  30.0);
    add_vector(inv_k, 0,  45.0);
    add_vector(inv_k, 0,  60.0);
    add_vector(inv_k, 0,  75.0);
    add_vector(inv_k, 0, -45.0);
    add_vector(inv_k, 0, -60.0);

    // 2. Edge angles (overflow at ±1.0 and quadrant folding)
    add_vector(inv_k, 0,    0.0);
    add_vector(inv_k, 0,   90.0);
    add_vector(inv_k, 0,  -90.0);
    add_vector(inv_k, 0, -180.0);
    add_vector(inv_k, 0,  179.9);
    add_vector(inv_k, 0, -179.9);
    add_vector(inv_k, 0,  100.0);
    add_vector(inv_k, 0, -100.0);
    add_vector(inv_k, 0,  120.0);
    add_vector(inv_k, 0,  135.0);
    add_vector(inv_k, 0,  170.0);
    add_vector(inv_k, 0, -150.0);

    // 3. Non-zero y0, negative x0, saturating results (Q1.15 values, rescaled)
    add_vector(q15( 9830), q15(13107),   30.0);   // (0.3, 0.4)
    add_vector(q15( 9830), q15(13107),  150.0);
    add_vector(q15(-16384), q15(6554),  -70.0);   // (−0.5, 0.2)
    add_vector(q15(-16384), q15(6554),  110.0);
    add_vector(q15(-32768),          0,    0.0);  // most negative input, folded case below
    add_vector(q15(-32768),          0,  180.0);
    add_vector(q15( 29491),          0,    0.0);  // 0.9·K > 1 → saturates to +max
    add_vector(q15( 29491),          0,  180.0);  //           → saturates to −max
    add_vector((1 << (inout_width-1)) - 1, (1 << (inout_width-1)) - 1, 45.0);  // |v|·K ≈ 2.33 → saturates

    // 4. Full-circle sweep
    for (ang = -180.0; ang < 180.0; ang = ang + 3.0)
      add_vector(inv_k, 0, ang);

    // 5. Random vectors with |(x, y)|·K < 1 (no saturation)
    for (i = 0; i < 200; i = i + 1)
      add_vector(q15($random(seed) % 13000), q15($random(seed) % 13000),
                 (($random(seed) % 18000) / 100.0));

    // Initialize
    resetn = 0;
    s_axis_x_tdata      = 0;
    s_axis_y_tdata      = 0;
    s_axis_phase_tdata  = 0;
    s_axis_x_tvalid     = 0;
    s_axis_y_tvalid     = 0;
    s_axis_phase_tvalid = 0;
    m_axis_x_tready     = 1;
    m_axis_y_tready     = 1;
    m_axis_phase_tready = 1;

    // Reset
    repeat (4) @(posedge aclk);
    resetn <= 1;
    repeat (2) @(posedge aclk);

    $display("============================================================");
`ifdef TB_USE_TOP
    $display("  CORDIC Circular Rotation Mode Testbench (DUT: cordic_top)");
`else
    $display("  CORDIC Circular Rotation Mode Testbench (DUT: cordic)");
`endif
    $display("  inout_width=%0d, phase_width=%0d, iterations=%0d",
             inout_width, phase_width, cordic_niter);
    $display("  guard_bits=%0d, phase_guard_bits=%0d, phase_output=%0d",
             guard_bits, phase_guard_bits, phase_output);
    $display("  Fixed-point: 1.0 = 2^%0d, pi = 2^%0d", inout_width-1, phase_width-1);
    $display("  K = %f, 1/K = %0d (pre-scaled input)", cordic_gain, inv_k);
    $display("  Vectors: %0d, tolerance: %0d LSB", n_vectors, TOLERANCE);
    n_phase_expected = (phase_output != 0) ? n_vectors : 0;
    $display("============================================================");

    $display("  Pass 0: back-to-back, no back-pressure");
    run_pass(1'b0);
    $display("  Pass 1: random tvalid gaps and tready back-pressure");
    run_pass(1'b1);
    $display("  Partial-valid check");
    partial_valid_check;

    // -----------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------
    $display("============================================================");
    $display("  Max error: x=%0d, y=%0d LSB, residual phase=%0d LSB",
             max_x_err, max_y_err, max_phase_err);
    $display("  Pass 0 throughput: one result every %0d cycles (expected %0d)",
             max_interval, cordic_niter);
    if (max_interval != cordic_niter) begin
      $display("  *** ERROR: pass 0 input interval %0d, expected %0d cycles",
               max_interval, cordic_niter);
      error_count = error_count + 1;
    end
    if (error_count > 0) begin
      $display("  *** %0d ERROR(S) ***", error_count);
      $display("============================================================");
      $fatal(1, "tb_cordic FAILED");
    end
    $display("  ALL TESTS PASSED (%0d vectors x 2 passes)", n_vectors);
    $display("============================================================");

    $finish;
  end

endmodule
