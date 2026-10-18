// =============================================================================
// Module: cordic_sqrt_wrapper
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Normalizes 32-bit unsigned integer inputs to compute square roots
// using the fixed-point hyperbolic CORDIC core.
//
// Algorithm:
//   1. LZD (Leading Zero Detector) finds the MSB position m of `rad`.
//   2. Pre-scaler: with e = floor(m/2) + 2, the input is mapped to
//          a = rad · 2^(−2e)  ∈ [1/16, 1/4)
//      which is inside the core's convergence range. The exponent is even,
//      so  √rad = √a · 2^e  exactly. In the Q1.39 core format this is a
//      pure LEFT shift by (35 − 2·floor(m/2)), so no input bits are lost.
//   3. Passes x0 = a + ¼, y0 = a − ¼ to the `cordic_sqrt` core
//      (40-bit datapath, 18 iterations: j = 1..16 with repeats at 4 and 13).
//   4. Post-scaler multiplies the output by the inverse hyperbolic gain
//      (1/K_h), shifts it by the exponent, rounds to nearest and saturates.
//   5. The result is registered (one-entry output buffer), so `root` and
//      `output_valid` come straight from flip-flops and the multiplier /
//      shifter path ends at a register instead of at the output port.
//
// Input:  32-bit Unsigned Integer
// Output: 32-bit Q16.16 Fixed Point, rounded to nearest
//         (√(2^32 − 1) rounds to 2^32 and is saturated to 0xFFFF_FFFF)
//
// Latency: 1 (capture) + 18 (iterations) + 1 (output register) cycles to
//          output_valid. Throughput: one result every 20 cycles.
// =============================================================================

`timescale 1ns / 1ps

module cordic_sqrt_wrapper (
    input clk,
    input resetn,

    input [31:0] rad,
    input input_valid,
    output input_ready,

    output [31:0] root,
    output output_valid,
    input output_ready
);

    // ── Core configuration ──
    localparam CORE_WIDTH  = 40;          // Q1.39
    localparam PHASE_WIDTH = 18;
    localparam N_ITER      = 18;          // j = 1..16 + repeats at 4, 13
    localparam ITER_WIDTH  = 5;
    localparam LUT_ENTRIES = N_ITER - 2;  // j_max = 16

    // 1/K_h for the 18-step sequence above, Q1.32:
    //   K_h = Π sqrt(1 − 2^(−2j)) = 0.82815936096...
    //   round(2^32 / K_h) = 5186160416
    localparam [33:0] INV_KH = 34'd5186160416;

    // 1. Leading Zero Detector (Find MSB)
    // Only msb[4:1] is needed: the shift depends on floor(m/2).
    /* verilator lint_off UNUSEDSIGNAL */
    reg [4:0] msb;
    /* verilator lint_on UNUSEDSIGNAL */
    integer i;
    always @(*) begin
        msb = 5'd0;
        for (i = 0; i < 32; i = i + 1)
            if (rad[i]) msb = i[4:0];
    end

    // 2. Pre-scale Shift
    // MSB lands on bit 35 (m even) or bit 36 (m odd) of the Q1.39 word,
    // i.e. a ∈ [2^-4, 2^-2). The shift is always odd and positive (5..35).
    wire [5:0] shift_amt = 6'd35 - {1'b0, msb[4:1], 1'b0};

    wire [CORE_WIDTH-1:0] a_norm = {{(CORE_WIDTH-32){1'b0}}, rad} << shift_amt;
    wire is_zero = (rad == 0);

    // 3. Register post-scaling exponent e = floor(m/2) + 2
    wire [4:0] e_comb = {1'b0, msb[4:1]} + 5'd2;
    reg  [4:0] e_reg;
    reg        is_zero_reg;

    wire core_ready;
    assign input_ready = core_ready;

    always @(posedge clk) begin
        if (!resetn) begin
            e_reg <= 0;
            is_zero_reg <= 0;
        end else if (input_valid && core_ready) begin
            e_reg <= e_comb;
            is_zero_reg <= is_zero;
        end
    end

    // 4. Instantiation
    localparam [CORE_WIDTH-1:0] QUARTER = {3'b001, {(CORE_WIDTH-3){1'b0}}};  // 0.25 in Q1.39
    wire signed [CORE_WIDTH-1:0] x_initial = is_zero ? {CORE_WIDTH{1'b0}} : (a_norm + QUARTER);
    wire signed [CORE_WIDTH-1:0] y_initial = is_zero ? {CORE_WIDTH{1'b0}} : (a_norm - QUARTER);

    wire signed [CORE_WIDTH-1:0] x_final;
    wire core_valid;
    wire core_out_ready;

    wire [ITER_WIDTH-1:0]         lut_address;
    wire signed [PHASE_WIDTH-1:0] elementary_angle;

    atanh_lut #(
      .PHASE_WIDTH (PHASE_WIDTH),
      .N_ENTRIES   (LUT_ENTRIES),
      .ADDR_WIDTH  (ITER_WIDTH)
    ) u_atanh_lut (
      .address (lut_address),
      .data    (elementary_angle)
    );

    cordic_sqrt #(
        .data_width(CORE_WIDTH),
        .phase_width(PHASE_WIDTH),
        .n_iterations(N_ITER),
        .iter_width(ITER_WIDTH),
        .guard_bits(0)              // 40-bit datapath already has ample LSBs
    ) core (
        .aclk(clk),
        .resetn(resetn),
        .x_initial(x_initial),
        .y_initial(y_initial),
        .z_initial({PHASE_WIDTH{1'b0}}),
        .input_valid(input_valid),
        .input_ready(core_ready),
        .lut_address(lut_address),
        .elementary_angle(elementary_angle),
        .x_final(x_final),
        /* verilator lint_off PINCONNECTEMPTY */
        .y_final(),
        .z_final(),
        /* verilator lint_on PINCONNECTEMPTY */
        .output_valid(core_valid),
        .output_ready(core_out_ready)
    );

    // 5. Post scale outputs
    //   x_final ≈ K_h · √a · 2^39   (positive, < 2^38)
    //   root    = √a · 2^e · 2^16 = x_final · INV_KH · 2^(e + 16 − 39 − 32)
    //           = (x_final · INV_KH) >> (55 − e)
    // Rounded to nearest by adding half an output LSB before the shift.
    localparam PW = CORE_WIDTH + 34;

    wire [PW-1:0] x_mult      = {{(PW-CORE_WIDTH){1'b0}}, x_final} * {{(PW-34){1'b0}}, INV_KH};
    wire [5:0]    post_shift  = 6'd55 - {1'b0, e_reg};
    wire [PW-1:0] round_half  = {{(PW-1){1'b0}}, 1'b1} << (post_shift - 6'd1);
    wire [PW-1:0] x_scaled    = (x_mult + round_half) >> post_shift;

    // Saturate (only reachable for rad close to 2^32)
    wire          overflow    = |x_scaled[PW-1:32];
    wire [31:0]   root_sat    = overflow ? 32'hFFFF_FFFF : x_scaled[31:0];

    wire [31:0]   root_next   = is_zero_reg ? 32'd0 : root_sat;

    // 6. Output register (one-entry buffer with valid/ready)
    //   The core result is moved into the register when it is empty or is
    //   being emptied in this same cycle, so back-to-back results lose no
    //   cycle. e_reg / is_zero_reg still belong to this result here: the core
    //   only accepts a new input after this transfer.
    reg [31:0] root_reg;
    reg        root_valid;

    assign core_out_ready = !root_valid || output_ready;
    wire   core_fire      = core_valid && core_out_ready;

    always @(posedge clk) begin
        if (!resetn) begin
            root_reg   <= 32'd0;
            root_valid <= 1'b0;
        end else if (core_fire) begin
            root_reg   <= root_next;
            root_valid <= 1'b1;
        end else if (output_ready) begin
            root_valid <= 1'b0;
        end
    end

    assign root         = root_reg;
    assign output_valid = root_valid;

endmodule
