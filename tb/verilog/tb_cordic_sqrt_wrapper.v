// =============================================================================
// Testbench: tb_cordic_sqrt_wrapper
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================

`timescale 1ns / 1ps

module tb_cordic_sqrt_wrapper;

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
  integer pass_count;
  integer test_count;
  
  // Tolerance in Q16.16 LSBs (allow roughly 0.05 margin of error due to fixed-point scaling loss)
  parameter TOLERANCE = 3276; 

  task run_wrapper_test;
    input [31:0] test_rad;
    input [31:0] expected_root_q16;
    input [255:0] test_name;
  begin
    test_count = test_count + 1;

    @(posedge clk);
    rad         <= test_rad;
    input_valid <= 1'b1;

    // Wait for handshake
    @(posedge clk);
    while (!(input_valid && input_ready)) @(posedge clk);
    @(posedge clk);
    input_valid <= 1'b0;

    // Wait for output
    while (!output_valid) @(posedge clk);
    @(posedge clk);

    begin : error_check
      integer err;
      err = (root > expected_root_q16) ? (root - expected_root_q16) : (expected_root_q16 - root);

      $display("------------------------------------------------------------");
      $display("  Test: %0s", test_name);
      $display("  Input rad    : %0d", test_rad);
      $display("  Output Root  : %0d (Q16.16) -> %f", root, root / 65536.0);
      $display("  Expected     : %0d (Q16.16) -> %f", expected_root_q16, expected_root_q16 / 65536.0);
      $display("  Error (LSBs) : %0d (Tolerance: %0d)", err, TOLERANCE);

      if (err <= TOLERANCE) begin
        $display("  Result: PASS");
        pass_count = pass_count + 1;
      end else begin
        $display("  Result: *** FAIL ***");
      end
    end

    @(posedge clk);
    @(posedge clk);
  end
  endtask

  // ── Main test sequence ──
  initial begin
    pass_count = 0;
    test_count = 0;

    resetn       = 0;
    input_valid  = 0;
    output_ready = 1;
    rad          = 0;
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (2) @(posedge clk);

    $display("============================================================");
    $display("  CORDIC SQRT Wrapper Testbench (Normalized Integer Input)");
    $display("============================================================");

    // Q16.16 representations: Integer * 65536
    run_wrapper_test(32'd4,     32'd131072,  "sqrt(4) == 2.0");
    run_wrapper_test(32'd9,     32'd196608,  "sqrt(9) == 3.0");
    run_wrapper_test(32'd16,    32'd262144,  "sqrt(16) == 4.0");
    run_wrapper_test(32'd25,    32'd327680,  "sqrt(25) == 5.0");
    run_wrapper_test(32'd100,   32'd655360,  "sqrt(100) == 10.0");
    run_wrapper_test(32'd10000, 32'd6553600, "sqrt(10000) == 100.0");
    
    // Boundary check zero
    run_wrapper_test(32'd0,     32'd0,       "sqrt(0) == 0.0");

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
