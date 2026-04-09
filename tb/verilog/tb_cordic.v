`timescale 1ns / 1ps

module tb_cordic();

  parameter inout_width = 16;
  parameter phase_width = 18;
  parameter cordic_niter = 16;
  parameter cordic_niter_width = 4;

  reg aclk;
  reg resetn;

  // slave AXI-Stream
  reg signed [inout_width-1:0] s_axis_real_tdata;
  reg s_axis_real_tvalid;
  wire s_axis_real_tready;

  reg signed [inout_width-1:0] s_axis_imag_tdata;
  reg s_axis_imag_tvalid;
  wire s_axis_imag_tready;

  reg signed [phase_width-1:0] s_axis_phase_tdata;
  reg s_axis_phase_tvalid;
  wire s_axis_phase_tready;

  // ATAN LUT
  wire [cordic_niter_width-1:0] atan_lut_address;
  reg signed [phase_width-1:0] atan_lut_data;

  // master AXI-Stream
  wire signed [inout_width-1:0] m_axis_real_tdata;
  wire m_axis_real_tvalid;
  reg m_axis_real_tready;

  wire signed [inout_width-1:0] m_axis_imag_tdata;
  wire m_axis_imag_tvalid;
  reg m_axis_imag_tready;

  wire signed [phase_width-1:0] m_axis_phase_tdata;
  wire m_axis_phase_tvalid;
  reg m_axis_phase_tready;

  // Instantiate the DUT
  cordic #(
    .inout_width(inout_width),
    .phase_width(phase_width),
    .cordic_niter(cordic_niter),
    .cordic_niter_width(cordic_niter_width)
  ) dut (
    .aclk(aclk),
    .resetn(resetn),

    .s_axis_real_tdata(s_axis_real_tdata),
    .s_axis_real_tvalid(s_axis_real_tvalid),
    .s_axis_real_tready(s_axis_real_tready),

    .s_axis_imag_tdata(s_axis_imag_tdata),
    .s_axis_imag_tvalid(s_axis_imag_tvalid),
    .s_axis_imag_tready(s_axis_imag_tready),

    .s_axis_phase_tdata(s_axis_phase_tdata),
    .s_axis_phase_tvalid(s_axis_phase_tvalid),
    .s_axis_phase_tready(s_axis_phase_tready),

    .atan_lut_address(atan_lut_address),
    .atan_lut_data(atan_lut_data),

    .m_axis_real_tdata(m_axis_real_tdata),
    .m_axis_real_tvalid(m_axis_real_tvalid),
    .m_axis_real_tready(m_axis_real_tready),

    .m_axis_imag_tdata(m_axis_imag_tdata),
    .m_axis_imag_tvalid(m_axis_imag_tvalid),
    .m_axis_imag_tready(m_axis_imag_tready),

    .m_axis_phase_tdata(m_axis_phase_tdata),
    .m_axis_phase_tvalid(m_axis_phase_tvalid),
    .m_axis_phase_tready(m_axis_phase_tready)
  );

  // Clock generation
  initial begin
    aclk = 0;
    forever #5 aclk = ~aclk; // 100MHz clock
  end

  // Dump waves
  initial begin
    $dumpfile("tb/dump.vcd");
    $dumpvars(0, tb_cordic);
  end

  // Mock LUT behavior
  // For this simple testbench, just return 0 for the generic LUT
  assign atan_lut_data = {phase_width{1'b0}}; 

  initial begin
    // Initialize inputs
    resetn = 0;
    s_axis_real_tdata = 0;
    s_axis_real_tvalid = 0;
    s_axis_imag_tdata = 0;
    s_axis_imag_tvalid = 0;
    s_axis_phase_tdata = 0;
    s_axis_phase_tvalid = 0;
    m_axis_real_tready = 1;
    m_axis_imag_tready = 1;
    m_axis_phase_tready = 1;

    // Reset sequence
    #20 resetn = 1;
    #10;

    // Apply inputs
    s_axis_real_tdata = 16'd1000;
    s_axis_imag_tdata = 16'd0;
    s_axis_phase_tdata = 18'd450;
    
    s_axis_real_tvalid = 1;
    s_axis_imag_tvalid = 1;
    s_axis_phase_tvalid = 1;

    // Wait for handshake
    wait(s_axis_real_tready && s_axis_real_tvalid);
    #10;
    
    // De-assert valid after handshake
    s_axis_real_tvalid = 0;
    s_axis_imag_tvalid = 0;
    s_axis_phase_tvalid = 0;

    // Wait for results
    wait(m_axis_real_tvalid);
    $display("Test Complete. x_out=%d, y_out=%d, z_out=%d", m_axis_real_tdata, m_axis_imag_tdata, m_axis_phase_tdata);
    
    #50 $finish;
  end

endmodule
