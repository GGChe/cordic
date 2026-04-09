`timescale 1ns / 1ps

module cordic #(
  parameter inout_width = 16,
  parameter phase_width = 18,
  parameter cordic_niter = 16,
  parameter cordic_niter_width = 4
)(
  input aclk, 
  input resetn,

  /* slave axis interface */
  input signed [inout_width-1:0] s_axis_real_tdata,
  input s_axis_real_tvalid,
  output s_axis_real_tready,

  input signed [inout_width-1:0] s_axis_imag_tdata,
  input s_axis_imag_tvalid,
  output s_axis_imag_tready,

  input signed [phase_width-1:0] s_axis_phase_tdata,
  input s_axis_phase_tvalid,
  output s_axis_phase_tready,

  /* atan look-up-table interface */
  output [cordic_niter_width-1:0] atan_lut_address,
  input signed [phase_width-1:0] atan_lut_data,

  /* master axis interface */
  output reg signed [inout_width-1:0] m_axis_real_tdata,
  output reg m_axis_real_tvalid,
  input m_axis_real_tready,

  output reg signed [inout_width-1:0] m_axis_imag_tdata,
  output reg m_axis_imag_tvalid,
  input m_axis_imag_tready,

  output reg signed [phase_width-1:0] m_axis_phase_tdata,
  output reg m_axis_phase_tvalid,
  input m_axis_phase_tready
);

  reg [2:0] cordic_state;
  reg [cordic_niter_width-1:0] iteration;
  
  reg signed [inout_width-1:0] real_tdata_temp;
  reg signed [inout_width-1:0] imag_tdata_temp;
  reg signed [phase_width-1:0] phase_tdata_temp;

  assign s_axis_real_tready = (cordic_state == 3'd0);
  assign s_axis_imag_tready = (cordic_state == 3'd0);
  assign s_axis_phase_tready = (cordic_state == 3'd0);
  assign atan_lut_address = iteration;

  always @(posedge aclk) begin
    if (!resetn) begin
      cordic_state <= 3'd0;
      m_axis_real_tvalid <= 1'b0;
      m_axis_imag_tvalid <= 1'b0;
      m_axis_phase_tvalid <= 1'b0;
      m_axis_real_tdata <= 0;
      m_axis_imag_tdata <= 0;
      m_axis_phase_tdata <= 0;
    end else begin
      case (cordic_state)
        3'd0: begin
          if ((s_axis_real_tvalid || s_axis_imag_tvalid || s_axis_phase_tvalid) && 
              (s_axis_real_tready && s_axis_imag_tready && s_axis_phase_tready)) begin
            cordic_state <= 3'd1;
          end else begin
            cordic_state <= 3'd0;
          end

          real_tdata_temp <= s_axis_real_tdata;
          imag_tdata_temp <= s_axis_imag_tdata;
          phase_tdata_temp <= s_axis_phase_tdata;
          iteration <= 0;

          m_axis_real_tvalid <= 1'b0;
          m_axis_imag_tvalid <= 1'b0;
          m_axis_phase_tvalid <= 1'b0;
        end
        3'd1: begin
          if (phase_tdata_temp[phase_width-1]) cordic_state <= 3'd2; /* phase < 0*/
          else cordic_state <= 3'd3;
        end
        3'd2: begin /* phase < 0 */
          if (iteration == (cordic_niter-1)) cordic_state <= 3'd4;
          else cordic_state <= 3'd1;

          real_tdata_temp <= real_tdata_temp + (imag_tdata_temp >>> iteration);
          imag_tdata_temp <= imag_tdata_temp - (real_tdata_temp >>> iteration);
          phase_tdata_temp <= phase_tdata_temp + atan_lut_data;

          iteration <= iteration + 1;
        end
        3'd3: begin /* phase > 0 */
          if (iteration == (cordic_niter-1)) cordic_state <= 3'd4;
          else cordic_state <= 3'd1;

          real_tdata_temp <= real_tdata_temp - (imag_tdata_temp >>> iteration);
          imag_tdata_temp <= imag_tdata_temp + (real_tdata_temp >>> iteration);
          phase_tdata_temp <= phase_tdata_temp - atan_lut_data;

          iteration <= iteration + 1;
        end
        3'd4: begin
          if (m_axis_real_tready && m_axis_imag_tready && m_axis_phase_tready) begin
              cordic_state <= 3'd0;
          end

          m_axis_real_tdata <= real_tdata_temp;
          m_axis_imag_tdata <= imag_tdata_temp;
          m_axis_phase_tdata <= phase_tdata_temp;
          m_axis_real_tvalid <= 1'b1;
          m_axis_imag_tvalid <= 1'b1;
          m_axis_phase_tvalid <= 1'b1;
        end
        default: cordic_state <= 3'd0;
      endcase
    end
  end

endmodule
