`timescale 1ns / 1ps

// =============================================================================
// Module: cordic_top
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Top-level wrapper that integrates the CORDIC core with the atan LUT ROM.
//
// This module is the "complete" CORDIC unit — it is self-contained and can be
// instantiated in a larger design without needing to externally provide
// the atan look-up table.
//
// Architecture:
//
//   ┌─────────────────────────────────────────────────────┐
//   │  cordic_top                                         │
//   │                                                     │
//   │   ┌──────────┐    address    ┌──────────┐           │
//   │   │          ├──────────────►│          │           │
//   │   │  cordic  │              │ atan_lut │           │
//   │   │  (core)  │◄──────────────┤  (ROM)   │           │
//   │   │          │     data      │          │           │
//   │   └──────────┘               └──────────┘           │
//   │                                                     │
//   └─────────────────────────────────────────────────────┘
//
// Parameters:
//   INOUT_WIDTH       — data path bit-width (default 16, Q1.15)
//   PHASE_WIDTH       — phase accumulator bit-width (default 18)
//   CORDIC_NITER      — number of CORDIC iterations (default 16)
//   CORDIC_NITER_WIDTH — ceil(log2(CORDIC_NITER)) (default 4)
// =============================================================================

module cordic_top #(
  parameter INOUT_WIDTH       = 16,
  parameter PHASE_WIDTH       = 18,
  parameter CORDIC_NITER      = 16,
  parameter CORDIC_NITER_WIDTH = 4
)(
  input aclk,
  input resetn,

  // AXIS Slave Interface (inputs)
  input  signed [INOUT_WIDTH-1:0]  s_axis_x_tdata,
  input                            s_axis_x_tvalid,
  output                           s_axis_x_tready,

  input  signed [INOUT_WIDTH-1:0]  s_axis_y_tdata,
  input                            s_axis_y_tvalid,
  output                           s_axis_y_tready,

  input  signed [PHASE_WIDTH-1:0]  s_axis_phase_tdata,
  input                            s_axis_phase_tvalid,
  output                           s_axis_phase_tready,

  // AXIS Master Interface (outputs)
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

  // -------------------------------------------------------------------------
  // Internal wires connecting the CORDIC core to the atan LUT
  // -------------------------------------------------------------------------
  wire [CORDIC_NITER_WIDTH-1:0]  lut_address;
  wire signed [PHASE_WIDTH-1:0]  lut_data;

  // -------------------------------------------------------------------------
  // Atan Look-Up Table (combinational ROM)
  // -------------------------------------------------------------------------
  atan_lut #(
    .PHASE_WIDTH (PHASE_WIDTH),
    .N_ENTRIES   (CORDIC_NITER),
    .ADDR_WIDTH  (CORDIC_NITER_WIDTH)
  ) u_atan_lut (
    .address (lut_address),
    .data    (lut_data)
  );

  // -------------------------------------------------------------------------
  // CORDIC Core (iterative, word-serial architecture)
  // -------------------------------------------------------------------------
  cordic #(
    .inout_width       (INOUT_WIDTH),
    .phase_width       (PHASE_WIDTH),
    .cordic_niter      (CORDIC_NITER),
    .cordic_niter_width(CORDIC_NITER_WIDTH)
  ) u_cordic (
    .aclk    (aclk),
    .resetn  (resetn),

    // Slave interface
    .s_axis_x_tdata     (s_axis_x_tdata),
    .s_axis_x_tvalid    (s_axis_x_tvalid),
    .s_axis_x_tready    (s_axis_x_tready),

    .s_axis_y_tdata     (s_axis_y_tdata),
    .s_axis_y_tvalid    (s_axis_y_tvalid),
    .s_axis_y_tready    (s_axis_y_tready),

    .s_axis_phase_tdata (s_axis_phase_tdata),
    .s_axis_phase_tvalid(s_axis_phase_tvalid),
    .s_axis_phase_tready(s_axis_phase_tready),

    // LUT interface (internal connection)
    .atan_lut_address   (lut_address),
    .atan_lut_data      (lut_data),

    // Master interface
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
