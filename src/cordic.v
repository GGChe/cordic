
// =============================================================================
// Module: cordic
// Author: Gabriel Galeote Checa
// Date: 2026
// License: MIT
// =============================================================================
// Circular CORDIC in Rotation Mode
//
// Algorithm:
//   Set x0, y0 to vector coordinates. Set z0 to the rotation angle.
//   After 16 iterations, rotates (x0, y0) by angle z0.
//   Output: 
//     x_out ≈ K · (x0·cos(z0) - y0·sin(z0))
//     y_out ≈ K · (y0·cos(z0) + x0·sin(z0))
//     where K ≈ 1.6467 is the circular CORDIC gain parameter.
//
// Key features of circular CORDIC (Rotation Mode):
//   1. Decision is based on sign of z (drive z → 0).
//   2. Equations: x_{i+1} = x_i - σ·(y_i >>> i)
//                 y_{i+1} = y_i + σ·(x_i >>> i)
//   3. Iterations start at i=0.
//   4. Iteration i increments normally (0, 1, 2, ..., 15). No repeated steps.
//   5. LUT contains atan(2^-i).
//
// Note: Final outputs must be scaled by 1/K ≈ 0.6072 externally.
// =============================================================================


`timescale 1ns / 1ps

module cordic #(
  parameter inout_width = 16,
  parameter phase_width = 18,
  parameter cordic_niter = 16,
  parameter cordic_niter_width = 4
)(
  input aclk, 
  input resetn,

  // AXIS4 PROTOCOL SLAVE INTERFACE
  /* slave axis interface */
  input signed [inout_width-1:0] s_axis_x_tdata,
  input s_axis_x_tvalid,
  output s_axis_x_tready,

  input signed [inout_width-1:0] s_axis_y_tdata,
  input s_axis_y_tvalid,
  output s_axis_y_tready,

  input signed [phase_width-1:0] s_axis_phase_tdata,
  input s_axis_phase_tvalid,
  output s_axis_phase_tready,

  /* atan look-up-table interface */
  output [cordic_niter_width-1:0] atan_lut_address,
  input signed [phase_width-1:0] atan_lut_data,

  /* master axis interface */
  output reg signed [inout_width-1:0] m_axis_x_tdata,
  output reg m_axis_x_tvalid,
  input m_axis_x_tready,

  output reg signed [inout_width-1:0] m_axis_y_tdata,
  output reg m_axis_y_tvalid,
  input m_axis_y_tready,

  output reg signed [phase_width-1:0] m_axis_phase_tdata,
  output reg m_axis_phase_tvalid,
  input m_axis_phase_tready
);
  // CORDIC STATE MACHINE 
  reg [2:0] cordic_state;
  // CORDIC ITERATION COUNTER
  reg [cordic_niter_width-1:0] iteration;
  
  reg signed [inout_width-1:0] x_tdata_temp;
  reg signed [inout_width-1:0] y_tdata_temp;
  reg signed [phase_width-1:0] phase_tdata_temp;

  assign s_axis_x_tready = (cordic_state == 3'd0);
  assign s_axis_y_tready = (cordic_state == 3'd0);
  assign s_axis_phase_tready = (cordic_state == 3'd0);
  assign atan_lut_address = iteration;

  always @(posedge aclk) begin
    if (!resetn) begin
      cordic_state <= 3'd0;
      m_axis_x_tvalid <= 1'b0;
      m_axis_y_tvalid <= 1'b0;
      m_axis_phase_tvalid <= 1'b0;
      m_axis_x_tdata <= 0;
      m_axis_y_tdata <= 0;
      m_axis_phase_tdata <= 0;
      // Reset internal registers
      x_tdata_temp <= 0;
      y_tdata_temp <= 0;
      phase_tdata_temp <= 0;
      iteration <= 0;
    end else begin
      case (cordic_state)
        // STATE 0: IDLE
        // 1. Initialization Phase: Wait for data and set starting conditions
        3'd0: begin
          // Input Capture: Require ALL channels valid (AND, not OR)
          if ((s_axis_x_tvalid && s_axis_y_tvalid && s_axis_phase_tvalid) && 
              (s_axis_x_tready && s_axis_y_tready && s_axis_phase_tready)) begin
            // Capture input only on valid handshake
            x_tdata_temp <= s_axis_x_tdata;
            y_tdata_temp <= s_axis_y_tdata;
            phase_tdata_temp <= s_axis_phase_tdata;
            iteration <= 0;
            cordic_state <= 3'd1; // State Transition to engine room
          end

          m_axis_x_tvalid <= 1'b0;
          m_axis_y_tvalid <= 1'b0;
          m_axis_phase_tvalid <= 1'b0;
        end
        // 2. The Iteration Flow: The "engine room" for micro-rotations
        // Direction Decision
        3'd1: begin
          if (phase_tdata_temp[phase_width-1]) cordic_state <= 3'd2; /* phase < 0*/
          else cordic_state <= 3'd3;
        end
        
        // Micro-rotation Execution (Clockwise)
        3'd2: begin /* phase < 0 */
          // Loop Control: move to completion if iterations are done
          if (iteration == (cordic_niter-1)) cordic_state <= 3'd4;
          else cordic_state <= 3'd1;

          // Shift-and-Add: Core CORDIC equations
          x_tdata_temp <= x_tdata_temp + (y_tdata_temp >>> iteration);
          y_tdata_temp <= y_tdata_temp - (x_tdata_temp >>> iteration);
          // LUT Access: update phase register
          phase_tdata_temp <= phase_tdata_temp + atan_lut_data;

          // Loop Control: Increment iteration
          iteration <= iteration + 1;
        end
        
        // Micro-rotation Execution (Counter-Clockwise)
        3'd3: begin /* phase > 0 */
          // Loop Control: move to completion if iterations are done
          if (iteration == (cordic_niter-1)) cordic_state <= 3'd4;
          else cordic_state <= 3'd1;

          // Shift-and-Add: Core CORDIC equations
          x_tdata_temp <= x_tdata_temp - (y_tdata_temp >>> iteration);
          y_tdata_temp <= y_tdata_temp + (x_tdata_temp >>> iteration);
          // LUT Access: update phase register
          phase_tdata_temp <= phase_tdata_temp - atan_lut_data;

          // Loop Control: Increment iteration
          iteration <= iteration + 1;
        end
        // 3. Post-Scaling and Output Phase
        3'd4: begin
          if (m_axis_x_tready && m_axis_y_tready && m_axis_phase_tready) begin
              cordic_state <= 3'd0;
          end

          // Data Presentation: Assign final values to master axis output ports
          m_axis_x_tdata <= x_tdata_temp;
          m_axis_y_tdata <= y_tdata_temp;
          m_axis_phase_tdata <= phase_tdata_temp;
          
          // Handshaking: Assert tvalid to indicate data is ready
          // Note: Missing scale compensation (1/K) must be done externally
          m_axis_x_tvalid <= 1'b1;
          m_axis_y_tvalid <= 1'b1;
          m_axis_phase_tvalid <= 1'b1;
        end
        default: cordic_state <= 3'd0;
      endcase
    end
  end

endmodule
