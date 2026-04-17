// =============================================================================
// Module: cordic_sqrt_wrapper
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Normalizes large 32-bit unsigned integer inputs to compute square roots
// using the fixed-point Q1.15 CORDIC core.
//
// Algorithm:
//   1. LZD (Leading Zero Detector) finds the MSB of the input `rad`.
//   2. Pre-scaler shifts the input into the safe Q1.15 domain of (0.0, 0.75).
//      The shift logic guarantees an ODD shift amount to preserve parity for
//      the square root exponent scaling.
//   3. Passes normalized value to `cordic_sqrt_optimized` core.
//   4. Post-scaler multiplies output by the inverse hyperbolic gain (1/K_h)
//      and shifts the output back up by the calculated exponent parity shift.
//
// Input:  32-bit Unsigned Integer
// Output: 32-bit Q16.16 Fixed Point
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

    // 1. Leading Zero Detector (Find MSB)
    reg [4:0] msb;
    always @(*) begin
        msb = 5'd0;
        if (rad[31]) msb = 5'd31;
        else if (rad[30]) msb = 5'd30;
        else if (rad[29]) msb = 5'd29;
        else if (rad[28]) msb = 5'd28;
        else if (rad[27]) msb = 5'd27;
        else if (rad[26]) msb = 5'd26;
        else if (rad[25]) msb = 5'd25;
        else if (rad[24]) msb = 5'd24;
        else if (rad[23]) msb = 5'd23;
        else if (rad[22]) msb = 5'd22;
        else if (rad[21]) msb = 5'd21;
        else if (rad[20]) msb = 5'd20;
        else if (rad[19]) msb = 5'd19;
        else if (rad[18]) msb = 5'd18;
        else if (rad[17]) msb = 5'd17;
        else if (rad[16]) msb = 5'd16;
        else if (rad[15]) msb = 5'd15;
        else if (rad[14]) msb = 5'd14;
        else if (rad[13]) msb = 5'd13;
        else if (rad[12]) msb = 5'd12;
        else if (rad[11]) msb = 5'd11;
        else if (rad[10]) msb = 5'd10;
        else if (rad[9]) msb = 5'd9;
        else if (rad[8]) msb = 5'd8;
        else if (rad[7]) msb = 5'd7;
        else if (rad[6]) msb = 5'd6;
        else if (rad[5]) msb = 5'd5;
        else if (rad[4]) msb = 5'd4;
        else if (rad[3]) msb = 5'd3;
        else if (rad[2]) msb = 5'd2;
        else if (rad[1]) msb = 5'd1;
        else if (rad[0]) msb = 5'd0;
    end

    // 2. Pre-scale Shifts
    // Target MSB pairs to explicitly fall to bit 13 or 12.
    // Shift Amount ensures parity is maintained (sqrt power of 2 shift)
    wire signed [5:0] shift_amt = 6'd11 - {1'b0, msb[4:1], 1'b0};
    
    wire [63:0] rad_ext = {32'd0, rad};
    wire [63:0] a_norm_64 = (shift_amt >= 0) ? (rad_ext << shift_amt) : (rad_ext >> (-shift_amt));
    
    wire [15:0] a_norm = a_norm_64[15:0];
    wire is_zero = (rad == 0);

    // 3. Register post-scaling exponent
    wire [4:0] p_comb = 5'd3 + {1'b0, msb[4:1]};
    reg [4:0] p_reg;
    reg is_zero_reg;
    
    wire core_ready;
    assign input_ready = core_ready;
    
    always @(posedge clk) begin
        if (!resetn) begin
            p_reg <= 0;
            is_zero_reg <= 0;
        end else if (input_valid && core_ready) begin
            p_reg <= p_comb;
            is_zero_reg <= is_zero;
        end
    end

    // 4. Instantiation
    localparam [15:0] QUARTER = 16'd8192;
    wire signed [15:0] x_initial = (is_zero) ? 16'd0 : ($signed(a_norm) + $signed(QUARTER));
    wire signed [15:0] y_initial = (is_zero) ? 16'd0 : ($signed(a_norm) - $signed(QUARTER));
    
    wire [15:0] x_final;
    wire core_valid;
    
    wire [3:0] lut_address;
    wire [17:0] elementary_angle;
    
    atanh_lut #(
      .PHASE_WIDTH (18),
      .N_ENTRIES   (14),
      .ADDR_WIDTH  (4)
    ) u_atanh_lut (
      .address (lut_address),
      .data    (elementary_angle)
    );
    
    cordic_sqrt_optimized #(
        .data_width(16),
        .phase_width(18),
        .n_iterations(16),
        .iter_width(4)
    ) core (
        .aclk(clk),
        .resetn(resetn),
        .x_initial(x_initial),
        .y_initial(y_initial),
        .z_initial(18'd0),
        .input_valid(input_valid),
        .input_ready(core_ready),
        .lut_address(lut_address),
        .elementary_angle(elementary_angle),
        .x_final(x_final),
        .y_final(),
        .z_final(),
        .output_valid(core_valid),
        .output_ready(output_ready)
    );
    
    // 5. Post scale outputs
    // 1/Kh = 1.20743 (79130 in Q16)
    wire [33:0] x_mult = x_final * 18'd79130;  
    wire [63:0] x_post_shift = {30'd0, x_mult} << p_reg;
    
    // Truncate out the Q16 multiplier scale to yield Q16.16 
    assign root = is_zero_reg ? 32'd0 : x_post_shift[47:16];
    assign output_valid = core_valid;

endmodule
