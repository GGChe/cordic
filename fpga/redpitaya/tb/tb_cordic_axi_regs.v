// ── tb_cordic_axi_regs ──
// Mirrors the board-side test: ID, scratch/LEDs, unmapped addresses, single
// operations of both cores against real-valued math, and bursts. AW and W are
// driven with independent random delays. $fatal on error.
// =============================================================================

`timescale 1ns / 1ps

module tb_cordic_axi_regs;

  localparam real PI = 3.14159265358979323846;

  reg         aclk = 1'b0;
  reg         aresetn = 1'b0;
  always #4 aclk = ~aclk;   // 125 MHz

  reg  [31:0] awaddr;  reg awvalid;  wire awready;
  reg  [31:0] wdata;   reg [3:0] wstrb;  reg wvalid;  wire wready;
  wire [ 1:0] bresp;   wire bvalid;  reg bready;
  reg  [31:0] araddr;  reg arvalid;  wire arready;
  wire [31:0] rdata;   wire [1:0] rresp;  wire rvalid;  reg rready;
  wire [ 7:0] led;

  cordic_axi_regs dut (
    .aclk(aclk), .aresetn(aresetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .led_o(led)
  );

  integer errors = 0;
  integer seed = 32'h00A1_1173;

  // ── AXI4-Lite master BFM ──
  task axi_write;
    input [31:0] addr;
    input [31:0] data;
    integer aw_delay, w_delay;
    reg aw_done, w_done;
    begin
      aw_delay = {$random(seed)} % 3;
      w_delay  = {$random(seed)} % 3;
      aw_done = 1'b0;
      w_done  = 1'b0;
      fork
        begin
          repeat (aw_delay) @(posedge aclk);
          awaddr <= addr; awvalid <= 1'b1;
          @(posedge aclk);
          while (!awready) @(posedge aclk);
          awvalid <= 1'b0;
        end
        begin
          repeat (w_delay) @(posedge aclk);
          wdata <= data; wstrb <= 4'hF; wvalid <= 1'b1;
          @(posedge aclk);
          while (!wready) @(posedge aclk);
          wvalid <= 1'b0;
        end
      join
      bready <= 1'b1;
      while (!bvalid) @(posedge aclk);
      @(posedge aclk);
      bready <= 1'b0;
      if (bresp !== 2'b00) begin
        $display("  *** write 0x%03h: BRESP=%0d", addr, bresp);
        errors = errors + 1;
      end
    end
  endtask

  task axi_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      araddr <= addr; arvalid <= 1'b1;
      @(posedge aclk);
      while (!arready) @(posedge aclk);
      arvalid <= 1'b0;
      rready <= 1'b1;
      while (!rvalid) @(posedge aclk);
      data = rdata;
      if (rresp !== 2'b00) begin
        $display("  *** read 0x%03h: RRESP=%0d", addr, rresp);
        errors = errors + 1;
      end
      @(posedge aclk);
      rready <= 1'b0;
    end
  endtask

  task expect_eq;
    input [31:0]  got;
    input [31:0]  want;
    input [255:0] what;
    begin
      if (got !== want) begin
        $display("  *** %0s: got 0x%08h, expected 0x%08h", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task wait_done;
    input [31:0] status_addr;
    reg   [31:0] st;
    integer n;
    begin
      n = 0;
      st = 0;
      while (!st[1] && n < 20000) begin
        axi_read(status_addr, st);
        n = n + 1;
      end
      if (!st[1]) begin
        $display("  *** timeout waiting for done at 0x%03h", status_addr);
        errors = errors + 1;
      end
    end
  endtask

  // ── Circular CORDIC single operation ──
  task check_rotation;
    input integer x0, y0;
    input real    deg;
    reg   [31:0]  r;
    integer z, xe, ye, xo, yo;
    real    zr, k;
    integer i;
    begin
      k = 1.0;
      for (i = 0; i < 16; i = i + 1) k = k * $sqrt(1.0 + 2.0 ** (-2 * i));
      z  = $rtoi(deg / 180.0 * 131072.0 + ((deg >= 0) ? 0.5 : -0.5));
      if (z >= 131072) z = z - 262144;
      zr = z * PI / 131072.0;
      xe = $rtoi(k * (x0 * $cos(zr) - y0 * $sin(zr)) + 32768.5) - 32768;
      ye = $rtoi(k * (y0 * $cos(zr) + x0 * $sin(zr)) + 32768.5) - 32768;
      if (xe > 32767) xe = 32767;  if (xe < -32768) xe = -32768;
      if (ye > 32767) ye = 32767;  if (ye < -32768) ye = -32768;

      axi_write(32'h108, x0);
      axi_write(32'h10C, y0);
      axi_write(32'h110, z);
      axi_write(32'h100, 32'h1);
      wait_done(32'h104);
      axi_read(32'h114, r); xo = $signed(r);
      axi_read(32'h118, r); yo = $signed(r);
      if (xo - xe > 2 || xe - xo > 2 || yo - ye > 2 || ye - yo > 2) begin
        $display("  *** rotate (%0d,%0d) by %0.1f deg: got (%0d,%0d) expected (%0d,%0d)",
                 x0, y0, deg, xo, yo, xe, ye);
        errors = errors + 1;
      end
    end
  endtask

  // ── Square root single operation ──
  task check_sqrt;
    input [31:0] rad;
    reg   [31:0] r;
    reg   [63:0] e;
    begin
      e = $sqrt(rad + 0.0) * 65536.0;
      if (e > 64'hFFFF_FFFF) e = 64'hFFFF_FFFF;
      axi_write(32'h208, rad);
      axi_write(32'h200, 32'h1);
      wait_done(32'h204);
      axi_read(32'h20C, r);
      if ({32'd0, r} > e + 64'd1 || {32'd0, r} + 64'd1 < e) begin
        $display("  *** sqrt(%0d): got %0d expected %0d", rad, r, e[31:0]);
        errors = errors + 1;
      end
    end
  endtask

  reg [31:0] r, cnt0, cyc;
  integer i;

  initial begin
    $dumpfile("fpga/redpitaya/tb/dump_axi.vcd");
    $dumpvars(0, tb_cordic_axi_regs);

    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
    araddr = 0; arvalid = 0; rready = 0;
    repeat (5) @(posedge aclk);
    aresetn <= 1'b1;
    repeat (3) @(posedge aclk);

    $display("============================================================");
    $display("  cordic_axi_regs — AXI4-Lite register interface testbench");
    $display("============================================================");

    // Identification and scratch/LEDs
    axi_read(32'h000, r);  expect_eq(r, 32'h4352_4443, "ID");
    axi_read(32'h004, r);  expect_eq(r, 32'h0001_0000, "VERSION");
    axi_write(32'h008, 32'hDEAD_BEE5);
    axi_read(32'h008, r);  expect_eq(r, 32'hDEAD_BEE5, "SCRATCH");
    expect_eq({28'd0, led[7:4]}, 32'h5, "LED[7:4] from SCRATCH");
    axi_read(32'h00C, cnt0);
    repeat (100) @(posedge aclk);
    axi_read(32'h00C, r);
    if (r - cnt0 < 100) begin
      $display("  *** CYCLES not counting (%0d → %0d)", cnt0, r);
      errors = errors + 1;
    end

    // Unmapped addresses: OKAY, read as zero, aliasing above 4 KiB
    axi_read(32'h3F0, r);         expect_eq(r, 32'h0, "unmapped read");
    axi_write(32'h3F0, 32'h1234);
    axi_read(32'h0010_0000, r);   expect_eq(r, 32'h4352_4443, "ID alias at +1 MiB");

    // Circular CORDIC
    $display("  Circular: single operations");
    check_rotation(19898, 0,   30.0);
    check_rotation(19898, 0,    0.0);
    check_rotation(19898, 0,   90.0);
    check_rotation(19898, 0, -135.0);
    check_rotation(19898, 0,  170.0);
    check_rotation(9830, 13107, -60.0);
    axi_read(32'h11C, r);
    if ($signed(r) > 16 || $signed(r) < -16) begin
      $display("  *** residual phase too large: %0d", $signed(r));
      errors = errors + 1;
    end

    $display("  Circular: burst of 100");
    axi_read(32'h124, cnt0);
    axi_write(32'h128, 100);
    axi_write(32'h100, 32'h2);
    wait_done(32'h104);
    axi_read(32'h120, cyc);
    axi_read(32'h124, r);
    expect_eq(r - cnt0, 100, "C_COUNT after burst");
    $display("    %0d cycles for 100 results → %0d.%02d cycles/result",
             cyc, cyc / 100, cyc % 100);
    check_rotation(19898, 0, 45.0);   // still correct after a burst

    // Square root
    $display("  Square root: single operations");
    check_sqrt(32'd2);
    check_sqrt(32'd0);
    check_sqrt(32'd1);
    check_sqrt(32'd10000);
    check_sqrt(32'h7FFF_FFFF);
    check_sqrt(32'hFFFF_FFFF);
    for (i = 0; i < 10; i = i + 1) check_sqrt($random(seed));

    $display("  Square root: burst of 100");
    axi_read(32'h214, cnt0);
    axi_write(32'h218, 100);
    axi_write(32'h200, 32'h2);
    wait_done(32'h204);
    axi_read(32'h210, cyc);
    axi_read(32'h214, r);
    expect_eq(r - cnt0, 100, "S_COUNT after burst");
    $display("    %0d cycles for 100 results → %0d.%02d cycles/result",
             cyc, cyc / 100, cyc % 100);

    $display("============================================================");
    if (errors > 0) begin
      $display("  *** %0d ERROR(S) ***", errors);
      $fatal(1, "tb_cordic_axi_regs FAILED");
    end
    $display("  ALL TESTS PASSED");
    $display("============================================================");
    $finish;
  end

endmodule
