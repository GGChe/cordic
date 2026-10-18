// =============================================================================
// red_pitaya_cordic_top — Red Pitaya STEMlab 125-14 top for the CORDIC test
// Author: Gabriel Galeote Checa, 2026 — License: MIT
// =============================================================================
// The PS reaches `cordic_axi_regs` at 0x4000_0000 through M_AXI_GP0; the PL
// runs on FCLK_CLK0 (125 MHz). Uses only the PS fixed I/O, DDR and the LEDs.
// =============================================================================

`timescale 1ns / 1ps

module red_pitaya_cordic_top (
  inout  [54-1:0] FIXED_IO_mio     ,
  inout           FIXED_IO_ps_clk  ,
  inout           FIXED_IO_ps_porb ,
  inout           FIXED_IO_ps_srstb,
  inout           FIXED_IO_ddr_vrn ,
  inout           FIXED_IO_ddr_vrp ,
  inout  [15-1:0] DDR_addr   ,
  inout  [ 3-1:0] DDR_ba     ,
  inout           DDR_cas_n  ,
  inout           DDR_ck_n   ,
  inout           DDR_ck_p   ,
  inout           DDR_cke    ,
  inout           DDR_cs_n   ,
  inout  [ 4-1:0] DDR_dm     ,
  inout  [32-1:0] DDR_dq     ,
  inout  [ 4-1:0] DDR_dqs_n  ,
  inout  [ 4-1:0] DDR_dqs_p  ,
  inout           DDR_odt    ,
  inout           DDR_ras_n  ,
  inout           DDR_reset_n,
  inout           DDR_we_n   ,
  output [ 8-1:0] led_o
);

  wire        clk;
  wire        resetn;

  wire [31:0] axi_awaddr;
  wire [ 2:0] axi_awprot;
  wire        axi_awvalid, axi_awready;
  wire [31:0] axi_wdata;
  wire [ 3:0] axi_wstrb;
  wire        axi_wvalid, axi_wready;
  wire [ 1:0] axi_bresp;
  wire        axi_bvalid, axi_bready;
  wire [31:0] axi_araddr;
  wire [ 2:0] axi_arprot;
  wire        axi_arvalid, axi_arready;
  wire [31:0] axi_rdata;
  wire [ 1:0] axi_rresp;
  wire        axi_rvalid, axi_rready;

  system system_i (
    .FIXED_IO_mio       (FIXED_IO_mio     ),
    .FIXED_IO_ps_clk    (FIXED_IO_ps_clk  ),
    .FIXED_IO_ps_porb   (FIXED_IO_ps_porb ),
    .FIXED_IO_ps_srstb  (FIXED_IO_ps_srstb),
    .FIXED_IO_ddr_vrn   (FIXED_IO_ddr_vrn ),
    .FIXED_IO_ddr_vrp   (FIXED_IO_ddr_vrp ),
    .DDR_addr           (DDR_addr         ),
    .DDR_ba             (DDR_ba           ),
    .DDR_cas_n          (DDR_cas_n        ),
    .DDR_ck_n           (DDR_ck_n         ),
    .DDR_ck_p           (DDR_ck_p         ),
    .DDR_cke            (DDR_cke          ),
    .DDR_cs_n           (DDR_cs_n         ),
    .DDR_dm             (DDR_dm           ),
    .DDR_dq             (DDR_dq           ),
    .DDR_dqs_n          (DDR_dqs_n        ),
    .DDR_dqs_p          (DDR_dqs_p        ),
    .DDR_odt            (DDR_odt          ),
    .DDR_ras_n          (DDR_ras_n        ),
    .DDR_reset_n        (DDR_reset_n      ),
    .DDR_we_n           (DDR_we_n         ),
    .FCLK_CLK0          (clk              ),
    .peripheral_aresetn (resetn           ),
    .M_AXI_awaddr       (axi_awaddr       ),
    .M_AXI_awprot       (axi_awprot       ),
    .M_AXI_awvalid      (axi_awvalid      ),
    .M_AXI_awready      (axi_awready      ),
    .M_AXI_wdata        (axi_wdata        ),
    .M_AXI_wstrb        (axi_wstrb        ),
    .M_AXI_wvalid       (axi_wvalid       ),
    .M_AXI_wready       (axi_wready       ),
    .M_AXI_bresp        (axi_bresp        ),
    .M_AXI_bvalid       (axi_bvalid       ),
    .M_AXI_bready       (axi_bready       ),
    .M_AXI_araddr       (axi_araddr       ),
    .M_AXI_arprot       (axi_arprot       ),
    .M_AXI_arvalid      (axi_arvalid      ),
    .M_AXI_arready      (axi_arready      ),
    .M_AXI_rdata        (axi_rdata        ),
    .M_AXI_rresp        (axi_rresp        ),
    .M_AXI_rvalid       (axi_rvalid       ),
    .M_AXI_rready       (axi_rready       )
  );

  cordic_axi_regs u_regs (
    .aclk          (clk        ),
    .aresetn       (resetn     ),
    .s_axi_awaddr  (axi_awaddr ),
    .s_axi_awvalid (axi_awvalid),
    .s_axi_awready (axi_awready),
    .s_axi_wdata   (axi_wdata  ),
    .s_axi_wstrb   (axi_wstrb  ),
    .s_axi_wvalid  (axi_wvalid ),
    .s_axi_wready  (axi_wready ),
    .s_axi_bresp   (axi_bresp  ),
    .s_axi_bvalid  (axi_bvalid ),
    .s_axi_bready  (axi_bready ),
    .s_axi_araddr  (axi_araddr ),
    .s_axi_arvalid (axi_arvalid),
    .s_axi_arready (axi_arready),
    .s_axi_rdata   (axi_rdata  ),
    .s_axi_rresp   (axi_rresp  ),
    .s_axi_rvalid  (axi_rvalid ),
    .s_axi_rready  (axi_rready ),
    .led_o         (led_o      )
  );

endmodule
