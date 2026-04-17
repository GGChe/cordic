// =============================================================================
// cordic_top — circular CORDIC core with its atan LUT
// Author: Gabriel Galeote Checa, 2026 — License: MIT
// =============================================================================
// Self-contained rotation-mode CORDIC: `cordic` plus `atan_lut`, the LUT
// generated at the core's internal phase width (PHASE_WIDTH + PHASE_GUARD_BITS).
// Parameters and ports are those of `cordic` (see cordic.v).
// =============================================================================

`timescale 1ns / 1ps

module cordic_top #(
  parameter INOUT_WIDTH        = 16,
  parameter PHASE_WIDTH        = 18,
  parameter CORDIC_NITER       = 16,
  parameter CORDIC_NITER_WIDTH = 4,
  parameter GUARD_BITS         = 4,
  parameter PHASE_GUARD_BITS   = 4,
  parameter PHASE_OUTPUT       = 1
)(
  input aclk,
  input resetn,

  input  signed [INOUT_WIDTH-1:0]  s_axis_x_tdata,
  input                            s_axis_x_tvalid,
  output                           s_axis_x_tready,

  input  signed [INOUT_WIDTH-1:0]  s_axis_y_tdata,
  input                            s_axis_y_tvalid,
  output                           s_axis_y_tready,

  input  signed [PHASE_WIDTH-1:0]  s_axis_phase_tdata,
  input                            s_axis_phase_tvalid,
  output                           s_axis_phase_tready,

  output signed [INOUT_WIDTH-1:0]  m_axis_x_tdata,
  output                           m_axis_x_tvalid,
  input                            m_axis_x_tready,

  output signed [INOUT_WIDTH-1:0]  m_axis_y_tdata,
  output                           m_axis_y_tvalid,
  input                            m_axis_y_tready,

  output signed [PHASE_WIDTH-1:0]  m_axis_phase_tdata,
  output                           m_axis_phase_tvalid,
  input                            m_axis_phase_tready
);

  localparam LUT_WIDTH = PHASE_WIDTH + PHASE_GUARD_BITS;

  wire [CORDIC_NITER_WIDTH-1:0]  lut_address;
  wire signed [LUT_WIDTH-1:0]    lut_data;

  atan_lut #(
    .PHASE_WIDTH (LUT_WIDTH),
    .N_ENTRIES   (CORDIC_NITER),
    .ADDR_WIDTH  (CORDIC_NITER_WIDTH)
  ) u_atan_lut (
    .address (lut_address),
    .data    (lut_data)
  );

  cordic #(
    .inout_width       (INOUT_WIDTH),
    .phase_width       (PHASE_WIDTH),
    .cordic_niter      (CORDIC_NITER),
    .cordic_niter_width(CORDIC_NITER_WIDTH),
    .guard_bits        (GUARD_BITS),
    .phase_guard_bits  (PHASE_GUARD_BITS),
    .phase_output      (PHASE_OUTPUT)
  ) u_cordic (
    .aclk    (aclk),
    .resetn  (resetn),

    .s_axis_x_tdata     (s_axis_x_tdata),
    .s_axis_x_tvalid    (s_axis_x_tvalid),
    .s_axis_x_tready    (s_axis_x_tready),

    .s_axis_y_tdata     (s_axis_y_tdata),
    .s_axis_y_tvalid    (s_axis_y_tvalid),
    .s_axis_y_tready    (s_axis_y_tready),

    .s_axis_phase_tdata (s_axis_phase_tdata),
    .s_axis_phase_tvalid(s_axis_phase_tvalid),
    .s_axis_phase_tready(s_axis_phase_tready),

    .atan_lut_address   (lut_address),
    .atan_lut_data      (lut_data),

    .m_axis_x_tdata     (m_axis_x_tdata),
    .m_axis_x_tvalid    (m_axis_x_tvalid),
    .m_axis_x_tready    (m_axis_x_tready),

    .m_axis_y_tdata     (m_axis_y_tdata),
    .m_axis_y_tvalid    (m_axis_y_tvalid),
    .m_axis_y_tready    (m_axis_y_tready),

    .m_axis_phase_tdata (m_axis_phase_tdata),
    .m_axis_phase_tvalid(m_axis_phase_tvalid),
    .m_axis_phase_tready(m_axis_phase_tready)
  );

endmodule
