// =============================================================================
// cordic_sqrt_wrapper — √x for 32-bit unsigned integers, Q16.16 result
// Author: Gabriel Galeote Checa, 2026 — License: MIT
// =============================================================================
// rad is normalised to a = rad·2^(−2e) ∈ [1/16, 1/4) (a lossless left shift
// into the Q1.39 core, e = floor(msb/2) + 2), then √rad = √a·2^e. The 40-bit
// `cordic_sqrt` core runs 18 iterations; a 5-stage pipeline multiplies by
// 1/K_h, shifts by e, rounds to nearest and saturates (√(2^32−1) → 0xFFFF_FFFF).
//
// Valid/ready handshake. Latency 1 + 18 + 5 cycles, one result every 20.
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

    localparam CORE_WIDTH  = 40;          // Q1.39
    localparam PHASE_WIDTH = 18;
    localparam N_ITER      = 18;          // j = 1..16 + repeats at 4, 13
    localparam ITER_WIDTH  = 5;
    localparam LUT_ENTRIES = N_ITER - 2;  // j_max = 16

    // round(2^32 / K_h), K_h = Π sqrt(1 − 2^(−2j)) over the 18-step sequence
    localparam [33:0] INV_KH = 34'd5186160416;

    // MSB position (only floor(msb/2) is used)
    /* verilator lint_off UNUSEDSIGNAL */
    reg [4:0] msb;
    /* verilator lint_on UNUSEDSIGNAL */
    integer i;
    always @(*) begin
        msb = 5'd0;
        for (i = 0; i < 32; i = i + 1)
            if (rad[i]) msb = i[4:0];
    end

    // Normalise: the MSB lands on bit 35 or 36, i.e. a ∈ [2^-4, 2^-2)
    wire [5:0] shift_amt = 6'd35 - {1'b0, msb[4:1], 1'b0};

    wire [CORE_WIDTH-1:0] a_norm = {{(CORE_WIDTH-32){1'b0}}, rad} << shift_amt;
    wire is_zero = (rad == 0);

    // Exponent e, captured with the input
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

    localparam [CORE_WIDTH-1:0] QUARTER = {3'b001, {(CORE_WIDTH-3){1'b0}}};  // 0.25 in Q1.39
    wire signed [CORE_WIDTH-1:0] x_initial = is_zero ? {CORE_WIDTH{1'b0}} : (a_norm + QUARTER);
    wire signed [CORE_WIDTH-1:0] y_initial = is_zero ? {CORE_WIDTH{1'b0}} : (a_norm - QUARTER);

    // x_final < 2^38: only [37:0] is used
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [CORE_WIDTH-1:0] x_final;
    /* verilator lint_on UNUSEDSIGNAL */
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
        .guard_bits(0)              // 40 bits are already enough
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

    // ── Post-scale pipeline: root = (x_final · INV_KH) >> (55 − e) ──
    //   S1 capture   S2 partial products (DSP)   S3 sum   S4 round   S5 shift,
    //   saturate → output register.
    // All stages advance together when the output register is free, so no
    // result is dropped or duplicated; e and is_zero travel with the data.
    localparam XW = 38;          // significant bits of x_final
    localparam PW = XW + 34;     // product width

    reg              v1, v2, v3, v4;
    reg              root_valid;
    reg  [31:0]      root_reg;

    wire advance = !root_valid || output_ready;
    assign core_out_ready = advance;
    wire core_fire = core_valid && advance;

    // S1
    reg  [XW-1:0]    x1;
    reg  [4:0]       e1;
    reg              z1;
    // S2
    reg  [17+34-1:0] p_lo2;
    reg  [21+34-1:0] p_hi2;
    reg  [4:0]       e2;
    reg              z2;
    // S3
    reg  [PW-1:0]    prod3;
    reg  [5:0]       sh3;
    reg              z3;
    // S4
    reg  [PW-1:0]    rnd4;
    reg  [5:0]       sh4;
    reg              z4;

    /* verilator lint_off UNUSEDSIGNAL */
    wire [PW-1:0]    scaled = rnd4 >> sh4;    // < 2^34
    /* verilator lint_on UNUSEDSIGNAL */
    wire             overflow = |scaled[33:32];  // rad close to 2^32

    always @(posedge clk) begin
        if (!resetn) begin
            v1 <= 1'b0;  v2 <= 1'b0;  v3 <= 1'b0;  v4 <= 1'b0;
            root_valid <= 1'b0;
            root_reg   <= 32'd0;
            x1 <= 0;  e1 <= 0;  z1 <= 0;
            p_lo2 <= 0;  p_hi2 <= 0;  e2 <= 0;  z2 <= 0;
            prod3 <= 0;  sh3 <= 0;  z3 <= 0;
            rnd4  <= 0;  sh4 <= 0;  z4 <= 0;
        end else if (advance) begin
            // S1
            v1 <= core_fire;
            x1 <= x_final[XW-1:0];
            e1 <= e_reg;
            z1 <= is_zero_reg;
            // S2
            v2    <= v1;
            p_lo2 <= x1[16:0]    * INV_KH;
            p_hi2 <= x1[XW-1:17] * INV_KH;
            e2    <= e1;
            z2    <= z1;
            // S3
            v3    <= v2;
            prod3 <= {{(PW-51){1'b0}}, p_lo2} + {p_hi2, 17'd0};
            sh3   <= 6'd55 - {1'b0, e2};
            z3    <= z2;
            // S4
            v4    <= v3;
            rnd4  <= prod3 + ({{(PW-1){1'b0}}, 1'b1} << (sh3 - 6'd1));
            sh4   <= sh3;
            z4    <= z3;
            // S5
            root_valid <= v4;
            root_reg   <= z4 ? 32'd0 : (overflow ? 32'hFFFF_FFFF : scaled[31:0]);
        end
    end

    assign root         = root_reg;
    assign output_valid = root_valid;

endmodule
