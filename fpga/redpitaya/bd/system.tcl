# Block design "system": PS7 (Red Pitaya PS configuration) → AXI Interconnect
# (AXI3 → AXI4-Lite) → external M_AXI at 0x4000_0000, plus FCLK_CLK0 and the
# reset. The 1 GiB window covers all of GP0, so every access gets an answer.
# Sourced by ../build.tcl.

set bd_dir [file dirname [file normalize [info script]]]

create_bd_design system

# ── External interfaces ──
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO

set m_axi [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI]
set_property -dict [list \
  CONFIG.PROTOCOL     {AXI4LITE} \
  CONFIG.ADDR_WIDTH   {32} \
  CONFIG.DATA_WIDTH   {32} \
] $m_axi

set fclk0 [create_bd_port -dir O -type clk FCLK_CLK0]
set_property -dict [list \
  CONFIG.ASSOCIATED_BUSIF {M_AXI} \
  CONFIG.ASSOCIATED_RESET {peripheral_aresetn} \
] $fclk0
create_bd_port -dir O -type rst peripheral_aresetn

# ── Processing system ──
source $bd_dir/ps7_config.tcl
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7]
configure_ps7 $ps7
# Only M_AXI_GP0 is used by the PL
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0         {1} \
  CONFIG.PCW_USE_M_AXI_GP1         {0} \
  CONFIG.PCW_USE_S_AXI_GP0         {0} \
  CONFIG.PCW_USE_S_AXI_GP1         {0} \
  CONFIG.PCW_USE_S_AXI_HP0         {0} \
  CONFIG.PCW_USE_S_AXI_HP1         {0} \
  CONFIG.PCW_USE_S_AXI_HP2         {0} \
  CONFIG.PCW_USE_S_AXI_HP3         {0} \
  CONFIG.PCW_USE_FABRIC_INTERRUPT  {0} \
  CONFIG.PCW_EN_CLK0_PORT          {1} \
  CONFIG.PCW_EN_RST0_PORT          {1} \
] $ps7

# ── Reset and interconnect ──
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic

# ── Connections ──
connect_bd_intf_net [get_bd_intf_ports DDR]      [get_bd_intf_pins processing_system7/DDR]
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7/FIXED_IO]
connect_bd_intf_net [get_bd_intf_pins processing_system7/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI]  [get_bd_intf_ports M_AXI]

connect_bd_net [get_bd_pins processing_system7/FCLK_CLK0] \
  [get_bd_pins processing_system7/M_AXI_GP0_ACLK] \
  [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
  [get_bd_pins axi_interconnect_0/ACLK] \
  [get_bd_pins axi_interconnect_0/S00_ACLK] \
  [get_bd_pins axi_interconnect_0/M00_ACLK] \
  [get_bd_ports FCLK_CLK0]

connect_bd_net [get_bd_pins processing_system7/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
  [get_bd_pins axi_interconnect_0/S00_ARESETN] \
  [get_bd_pins axi_interconnect_0/M00_ARESETN] \
  [get_bd_ports peripheral_aresetn]

# The PS PLL gives 124.999999 MHz; copy the exact value to the external ports
set fclk_hz [get_property CONFIG.FREQ_HZ [get_bd_pins processing_system7/FCLK_CLK0]]
set_property CONFIG.FREQ_HZ $fclk_hz [get_bd_ports FCLK_CLK0]
set_property CONFIG.FREQ_HZ $fclk_hz [get_bd_intf_ports M_AXI]

# ── Address map ──
assign_bd_address -offset 0x40000000 -range 1G \
  -target_address_space [get_bd_addr_spaces processing_system7/Data] \
  [get_bd_addr_segs M_AXI/Reg] -force

validate_bd_design
save_bd_design
