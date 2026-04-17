// =============================================================================
// cordic_axi_regs — AXI4-Lite registers to test the CORDIC cores from the PS
// Author: Gabriel Galeote Checa, 2026 — License: MIT
// =============================================================================
// Wraps `cordic_top` and `cordic_sqrt_wrapper`. Every access completes with
// OKAY (unmapped offsets read 0); only addr[11:2] is decoded, so the 4 KiB map
// repeats across the window. Bursts feed the same input back-to-back with the
// outputs always ready: C_CYCLES / C_BURST_N is the sustained throughput.
//
//   0x000 ID       R  0x43524443 ("CRDC")    0x004 VERSION R  0x00010000
//   0x008 SCRATCH  RW [3:0] → LED[7:4]       0x00C CYCLES  R  free-running
//
//   Circular                                 Square root
//   0x100 C_CTRL      W  bit0 start, bit1 burst     0x200 S_CTRL     W
//   0x104 C_STATUS    R  bit0 busy, bit1 done,      0x204 S_STATUS   R
//                        bit2 input ready
//   0x108 C_X_IN      RW Q1.15                      0x208 S_RAD_IN   RW u32
//   0x10C C_Y_IN      RW Q1.15                      0x20C S_ROOT_OUT R  Q16.16
//   0x110 C_PHASE_IN  RW π = 2^17                   0x210 S_CYCLES   R
//   0x114 C_X_OUT     R  sign-extended              0x214 S_COUNT    R
//   0x118 C_Y_OUT     R  sign-extended              0x218 S_BURST_N  RW
//   0x11C C_PHASE_OUT R  residual phase
//   0x120 C_CYCLES    R  start → last result
//   0x124 C_COUNT     R  results since reset
//   0x128 C_BURST_N   RW burst length
//
// LEDs: [0] heartbeat, [1] circular done, [2] sqrt done, [3] busy, [7:4] SCRATCH.
// =============================================================================

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDSIGNAL */   // upper address bits are not decoded
/* verilator lint_off PINCONNECTEMPTY */
module cordic_axi_regs (
  input             aclk,
  input             aresetn,

  input      [31:0] s_axi_awaddr,
  input             s_axi_awvalid,
  output            s_axi_awready,
  input      [31:0] s_axi_wdata,
  input      [ 3:0] s_axi_wstrb,
  input             s_axi_wvalid,
  output            s_axi_wready,
  output     [ 1:0] s_axi_bresp,
  output reg        s_axi_bvalid,
  input             s_axi_bready,
  input      [31:0] s_axi_araddr,
  input             s_axi_arvalid,
  output            s_axi_arready,
  output reg [31:0] s_axi_rdata,
  output     [ 1:0] s_axi_rresp,
  output reg        s_axi_rvalid,
  input             s_axi_rready,

  output     [ 7:0] led_o
);

  localparam [31:0] ID      = 32'h4352_4443;  // "CRDC"
  localparam [31:0] VERSION = 32'h0001_0000;

  // ── AXI4-Lite ──
  // AW and W are captured independently; the write happens once both are held.
  reg        aw_held, w_held;
  reg [11:0] aw_addr;
  reg [31:0] w_data;
  reg [ 3:0] w_strb;

  assign s_axi_awready = !aw_held && !s_axi_bvalid;
  assign s_axi_wready  = !w_held  && !s_axi_bvalid;
  assign s_axi_bresp   = 2'b00;  // OKAY
  assign s_axi_rresp   = 2'b00;  // OKAY
  assign s_axi_arready = !s_axi_rvalid;

  wire       wr_en   = aw_held && w_held && !s_axi_bvalid;
  wire [9:0] wr_word = aw_addr[11:2];

  always @(posedge aclk) begin
    if (!aresetn) begin
      aw_held      <= 1'b0;
      w_held       <= 1'b0;
      aw_addr      <= 12'd0;
      w_data       <= 32'd0;
      w_strb       <= 4'd0;
      s_axi_bvalid <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_held <= 1'b1;
        aw_addr <= s_axi_awaddr[11:0];
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_held <= 1'b1;
        w_data <= s_axi_wdata;
        w_strb <= s_axi_wstrb;
      end
      if (wr_en) begin
        aw_held      <= 1'b0;
        w_held       <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  // Apply the write strobes
  function [31:0] merge;
    input [31:0] old_value;
    input [31:0] new_value;
    input [ 3:0] strb;
    integer b;
    begin
      for (b = 0; b < 4; b = b + 1)
        merge[8*b +: 8] = strb[b] ? new_value[8*b +: 8] : old_value[8*b +: 8];
    end
  endfunction

  // Word indices (byte offset / 4)
  localparam [9:0] R_ID          = 10'h000;
  localparam [9:0] R_VERSION     = 10'h001;
  localparam [9:0] R_SCRATCH     = 10'h002;
  localparam [9:0] R_CYCLES      = 10'h003;

  localparam [9:0] R_C_CTRL      = 10'h040;
  localparam [9:0] R_C_STATUS    = 10'h041;
  localparam [9:0] R_C_X_IN      = 10'h042;
  localparam [9:0] R_C_Y_IN      = 10'h043;
  localparam [9:0] R_C_PHASE_IN  = 10'h044;
  localparam [9:0] R_C_X_OUT     = 10'h045;
  localparam [9:0] R_C_Y_OUT     = 10'h046;
  localparam [9:0] R_C_PHASE_OUT = 10'h047;
  localparam [9:0] R_C_CYCLES    = 10'h048;
  localparam [9:0] R_C_COUNT     = 10'h049;
  localparam [9:0] R_C_BURST_N   = 10'h04A;

  localparam [9:0] R_S_CTRL      = 10'h080;
  localparam [9:0] R_S_STATUS    = 10'h081;
  localparam [9:0] R_S_RAD_IN    = 10'h082;
  localparam [9:0] R_S_ROOT_OUT  = 10'h083;
  localparam [9:0] R_S_CYCLES    = 10'h084;
  localparam [9:0] R_S_COUNT     = 10'h085;
  localparam [9:0] R_S_BURST_N   = 10'h086;

  // ── Writable registers ──
  reg [31:0] scratch;
  reg [31:0] c_x_in, c_y_in, c_phase_in, c_burst_n;
  reg [31:0] s_rad_in, s_burst_n;

  wire c_start_single = wr_en && (wr_word == R_C_CTRL) && w_strb[0] && w_data[0];
  wire c_start_burst  = wr_en && (wr_word == R_C_CTRL) && w_strb[0] && w_data[1];
  wire s_start_single = wr_en && (wr_word == R_S_CTRL) && w_strb[0] && w_data[0];
  wire s_start_burst  = wr_en && (wr_word == R_S_CTRL) && w_strb[0] && w_data[1];

  always @(posedge aclk) begin
    if (!aresetn) begin
      scratch    <= 32'd0;
      c_x_in     <= 32'd0;
      c_y_in     <= 32'd0;
      c_phase_in <= 32'd0;
      c_burst_n  <= 32'd1;
      s_rad_in   <= 32'd0;
      s_burst_n  <= 32'd1;
    end else if (wr_en) begin
      case (wr_word)
        R_SCRATCH:    scratch    <= merge(scratch,    w_data, w_strb);
        R_C_X_IN:     c_x_in     <= merge(c_x_in,     w_data, w_strb);
        R_C_Y_IN:     c_y_in     <= merge(c_y_in,     w_data, w_strb);
        R_C_PHASE_IN: c_phase_in <= merge(c_phase_in, w_data, w_strb);
        R_C_BURST_N:  c_burst_n  <= merge(c_burst_n,  w_data, w_strb);
        R_S_RAD_IN:   s_rad_in   <= merge(s_rad_in,   w_data, w_strb);
        R_S_BURST_N:  s_burst_n  <= merge(s_burst_n,  w_data, w_strb);
        default: ;
      endcase
    end
  end

  reg [31:0] cycles;
  always @(posedge aclk) begin
    if (!aresetn) cycles <= 32'd0;
    else          cycles <= cycles + 32'd1;
  end

  // ── Circular CORDIC ──
  wire               c_in_ready;
  wire signed [15:0] c_x_out, c_y_out;
  wire signed [17:0] c_phase_out;
  wire               c_x_valid, c_y_valid, c_phase_valid;

  reg  [31:0] c_to_issue;     // inputs still to be sent
  reg  [31:0] c_to_receive;   // results still expected
  reg  [31:0] c_cycles, c_count;
  reg  [31:0] c_x_res, c_y_res, c_phase_res;
  reg         c_done;

  wire c_busy      = (c_to_receive != 32'd0);
  wire c_in_valid  = (c_to_issue != 32'd0);
  wire c_in_fire   = c_in_valid && c_in_ready;
  // Outputs are always ready, so the three channels complete together
  wire c_out_fire  = c_x_valid;

  cordic_top u_cordic (
    .aclk                (aclk),
    .resetn              (aresetn),
    .s_axis_x_tdata      (c_x_in[15:0]),
    .s_axis_x_tvalid     (c_in_valid),
    .s_axis_x_tready     (c_in_ready),
    .s_axis_y_tdata      (c_y_in[15:0]),
    .s_axis_y_tvalid     (c_in_valid),
    .s_axis_y_tready     (),
    .s_axis_phase_tdata  (c_phase_in[17:0]),
    .s_axis_phase_tvalid (c_in_valid),
    .s_axis_phase_tready (),
    .m_axis_x_tdata      (c_x_out),
    .m_axis_x_tvalid     (c_x_valid),
    .m_axis_x_tready     (1'b1),
    .m_axis_y_tdata      (c_y_out),
    .m_axis_y_tvalid     (c_y_valid),
    .m_axis_y_tready     (1'b1),
    .m_axis_phase_tdata  (c_phase_out),
    .m_axis_phase_tvalid (c_phase_valid),
    .m_axis_phase_tready (1'b1)
  );

  always @(posedge aclk) begin
    if (!aresetn) begin
      c_to_issue   <= 32'd0;
      c_to_receive <= 32'd0;
      c_cycles     <= 32'd0;
      c_count      <= 32'd0;
      c_x_res      <= 32'd0;
      c_y_res      <= 32'd0;
      c_phase_res  <= 32'd0;
      c_done       <= 1'b0;
    end else begin
      if ((c_start_single || c_start_burst) && !c_busy) begin
        c_to_issue   <= c_start_burst ? ((c_burst_n == 0) ? 32'd1 : c_burst_n) : 32'd1;
        c_to_receive <= c_start_burst ? ((c_burst_n == 0) ? 32'd1 : c_burst_n) : 32'd1;
        c_cycles     <= 32'd0;
        c_done       <= 1'b0;
      end else begin
        if (c_busy) c_cycles <= c_cycles + 32'd1;
        if (c_in_fire) c_to_issue <= c_to_issue - 32'd1;
        if (c_out_fire) begin
          c_x_res      <= {{16{c_x_out[15]}}, c_x_out};
          c_y_res      <= {{16{c_y_out[15]}}, c_y_out};
          c_phase_res  <= {{14{c_phase_out[17]}}, c_phase_out};
          c_count      <= c_count + 32'd1;
          if (c_to_receive != 32'd0) begin
            c_to_receive <= c_to_receive - 32'd1;
            if (c_to_receive == 32'd1) c_done <= 1'b1;
          end
        end
      end
    end
  end

  // ── Square root ──
  wire        s_in_ready;
  wire [31:0] s_root;
  wire        s_out_valid;

  reg  [31:0] s_to_issue, s_to_receive;
  reg  [31:0] s_cycles, s_count, s_root_res;
  reg         s_done;

  wire s_busy     = (s_to_receive != 32'd0);
  wire s_in_valid = (s_to_issue != 32'd0);
  wire s_in_fire  = s_in_valid && s_in_ready;
  wire s_out_fire = s_out_valid;   // output_ready held high

  cordic_sqrt_wrapper u_sqrt (
    .clk          (aclk),
    .resetn       (aresetn),
    .rad          (s_rad_in),
    .input_valid  (s_in_valid),
    .input_ready  (s_in_ready),
    .root         (s_root),
    .output_valid (s_out_valid),
    .output_ready (1'b1)
  );

  always @(posedge aclk) begin
    if (!aresetn) begin
      s_to_issue   <= 32'd0;
      s_to_receive <= 32'd0;
      s_cycles     <= 32'd0;
      s_count      <= 32'd0;
      s_root_res   <= 32'd0;
      s_done       <= 1'b0;
    end else begin
      if ((s_start_single || s_start_burst) && !s_busy) begin
        s_to_issue   <= s_start_burst ? ((s_burst_n == 0) ? 32'd1 : s_burst_n) : 32'd1;
        s_to_receive <= s_start_burst ? ((s_burst_n == 0) ? 32'd1 : s_burst_n) : 32'd1;
        s_cycles     <= 32'd0;
        s_done       <= 1'b0;
      end else begin
        if (s_busy) s_cycles <= s_cycles + 32'd1;
        if (s_in_fire) s_to_issue <= s_to_issue - 32'd1;
        if (s_out_fire) begin
          s_root_res <= s_root;
          s_count    <= s_count + 32'd1;
          if (s_to_receive != 32'd0) begin
            s_to_receive <= s_to_receive - 32'd1;
            if (s_to_receive == 32'd1) s_done <= 1'b1;
          end
        end
      end
    end
  end

  // ── Read path ──
  reg [31:0] rd_mux;
  always @(*) begin
    case (s_axi_araddr[11:2])
      R_ID:          rd_mux = ID;
      R_VERSION:     rd_mux = VERSION;
      R_SCRATCH:     rd_mux = scratch;
      R_CYCLES:      rd_mux = cycles;

      R_C_STATUS:    rd_mux = {29'd0, c_in_ready, c_done, c_busy};
      R_C_X_IN:      rd_mux = c_x_in;
      R_C_Y_IN:      rd_mux = c_y_in;
      R_C_PHASE_IN:  rd_mux = c_phase_in;
      R_C_X_OUT:     rd_mux = c_x_res;
      R_C_Y_OUT:     rd_mux = c_y_res;
      R_C_PHASE_OUT: rd_mux = c_phase_res;
      R_C_CYCLES:    rd_mux = c_cycles;
      R_C_COUNT:     rd_mux = c_count;
      R_C_BURST_N:   rd_mux = c_burst_n;

      R_S_STATUS:    rd_mux = {29'd0, s_in_ready, s_done, s_busy};
      R_S_RAD_IN:    rd_mux = s_rad_in;
      R_S_ROOT_OUT:  rd_mux = s_root_res;
      R_S_CYCLES:    rd_mux = s_cycles;
      R_S_COUNT:     rd_mux = s_count;
      R_S_BURST_N:   rd_mux = s_burst_n;

      default:       rd_mux = 32'd0;
    endcase
  end

  always @(posedge aclk) begin
    if (!aresetn) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= 32'd0;
    end else if (s_axi_arvalid && s_axi_arready) begin
      s_axi_rvalid <= 1'b1;
      s_axi_rdata  <= rd_mux;
    end else if (s_axi_rvalid && s_axi_rready) begin
      s_axi_rvalid <= 1'b0;
    end
  end

  assign led_o = {scratch[3:0], c_busy | s_busy, s_done, c_done, cycles[26]};

endmodule
/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
