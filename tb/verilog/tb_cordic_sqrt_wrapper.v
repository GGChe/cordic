// =============================================================================
// Testbench: tb_cordic_sqrt_wrapper
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Self-checking testbench for the normalized integer square root wrapper.
//
//   root = round(√rad · 2^16)  (Q16.16), saturated to 0xFFFF_FFFF
//
// Test vectors:
//   - small integers and perfect squares (0, 1, 2, 3, 4, 9, ..., 10000)
//   - 2^k − 1, 2^k, 2^k + 1 for every k (exercises every normalization shift)
//   - the top of the range (2^31 − 1, 0xFFFE0001, 0xFFFF_FFFF)
//   - random 32-bit values
//
// The set is run twice: back-to-back with output_ready always high, then
// with random input gaps and random output back-pressure. A monitor checks
// that the output stays stable while stalled and that exactly one result is
// produced per input.
//
// Exits with $fatal on any failure so it can be used in CI.
// =============================================================================

`timescale 1ns / 1ps

module tb_cordic_sqrt_wrapper;

  // Tolerance in Q16.16 LSBs
  parameter TOLERANCE = 1;

  localparam MAX_VECTORS = 512;

  // ── DUT signals ──
  reg          clk;
  reg          resetn;
  reg  [31:0]  rad;
  reg          input_valid;
  wire         input_ready;
  wire [31:0]  root;
  wire         output_valid;
  reg          output_ready;

  // ── DUT Instantiation ──
  cordic_sqrt_wrapper dut (
    .clk          (clk),
    .resetn       (resetn),
    .rad          (rad),
    .input_valid  (input_valid),
    .input_ready  (input_ready),
    .root         (root),
    .output_valid (output_valid),
    .output_ready (output_ready)
  );

  // ── Clock generation ──
  initial clk = 0;
  always #5 clk = ~clk;

  // ── Waveform dump ──
  initial begin
    $dumpfile("tb/dump_wrapper.vcd");
    $dumpvars(0, tb_cordic_sqrt_wrapper);
  end

  // ── Test infrastructure ──
  reg [31:0] vec_rad  [0:MAX_VECTORS-1];
  reg [31:0] exp_root [0:MAX_VECTORS-1];
  integer    n_vectors;

  integer error_count;
  integer max_err;
  integer seed;
  reg     backpressure;

  task add_vector;
    input [31:0] r;
    reg   [63:0] e;
    begin
      // real → integer assignment rounds to nearest
      e = $sqrt(r + 0.0) * 65536.0;
      if (e > 64'hFFFF_FFFF) e = 64'hFFFF_FFFF;
      vec_rad[n_vectors]  = r;
      exp_root[n_vectors] = e[31:0];
      n_vectors = n_vectors + 1;
    end
  endtask

  // ── Output ready generator ──
  always @(posedge clk)
    output_ready <= backpressure ? (($random(seed) & 3) != 0) : 1'b1;

  // ── Monitor / scoreboard ──
  integer     beats;
  reg         prev_stall;
  reg [31:0]  prev_root;

  always @(posedge clk) begin : monitor
    integer err;
    if (!resetn) begin
      prev_stall <= 1'b0;
    end else begin
      if (prev_stall && (!output_valid || root !== prev_root)) begin
        $display("  *** PROTOCOL ERROR @%0t: output changed while stalled", $time);
        error_count = error_count + 1;
      end
      prev_stall <= output_valid && !output_ready;
      prev_root  <= root;

      if (output_valid && output_ready) begin
        if (beats >= n_vectors) begin
          $display("  *** ERROR @%0t: unexpected extra output", $time);
          error_count = error_count + 1;
        end else begin
          err = (root > exp_root[beats]) ? (root - exp_root[beats]) : (exp_root[beats] - root);
          if (err > max_err) max_err = err;
          if (err > TOLERANCE) begin
            $display("  *** FAIL sqrt(%0d): got %0d (%f), expected %0d (%f), error %0d LSB",
                     vec_rad[beats], root, root / 65536.0,
                     exp_root[beats], exp_root[beats] / 65536.0, err);
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

        rad         <= vec_rad[i];
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
      repeat (30) @(posedge clk);
    end
  endtask

  // ── Main test sequence ──
  integer i;

  initial begin
    seed = 32'h5A5A_0001;
    error_count = 0;
    max_err = 0;
    n_vectors = 0;
    backpressure = 1'b0;

    // Original cases + small integers
    add_vector(32'd4);
    add_vector(32'd9);
    add_vector(32'd16);
    add_vector(32'd25);
    add_vector(32'd100);
    add_vector(32'd10000);
    add_vector(32'd0);
    add_vector(32'd1);
    add_vector(32'd2);
    add_vector(32'd3);
    add_vector(32'd1000000);

    // Every normalization shift
    for (i = 1; i < 32; i = i + 1) begin
      add_vector((32'd1 << i) - 32'd1);
      add_vector( 32'd1 << i);
      add_vector((32'd1 << i) + 32'd1);
    end

    // Top of the range
    add_vector(32'h7FFF_FFFF);
    add_vector(32'hFFFE_0001);   // 65535^2
    add_vector(32'hFFFF_FFFE);
    add_vector(32'hFFFF_FFFF);   // rounds to 2^32 → saturates

    // Random values
    for (i = 0; i < 300; i = i + 1)
      add_vector($random(seed));

    resetn       = 0;
    input_valid  = 0;
    output_ready = 1;
    rad          = 0;
    repeat (4) @(posedge clk);
    resetn <= 1;
    repeat (2) @(posedge clk);

    $display("============================================================");
    $display("  CORDIC SQRT Wrapper Testbench (Normalized Integer Input)");
    $display("  Vectors: %0d, tolerance: %0d LSB (Q16.16)", n_vectors, TOLERANCE);
    $display("============================================================");

    $display("  Pass 0: back-to-back, no back-pressure");
    run_pass(1'b0);
    $display("  Pass 1: random input gaps and output back-pressure");
    run_pass(1'b1);

    $display("============================================================");
    $display("  Max error: %0d LSB (Q16.16)", max_err);
    if (error_count > 0) begin
      $display("  *** %0d ERROR(S) ***", error_count);
      $display("============================================================");
      $fatal(1, "tb_cordic_sqrt_wrapper FAILED");
    end
    $display("  ALL TESTS PASSED (%0d vectors x 2 passes)", n_vectors);
    $display("============================================================");

    $finish;
  end

endmodule
