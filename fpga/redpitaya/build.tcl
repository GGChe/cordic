# Vivado batch build of the Red Pitaya CORDIC test; fails if timing is not met.
#
#   vivado -mode batch -source build.tcl -tclargs [part] [jobs]
#
# part defaults to xc7z020clg400-1. Writes out/cordic_rp.bit, out/cordic_rp.bit.bin
# (for fpgautil) and the utilization/timing reports.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize $script_dir/../..]
set build_dir  $script_dir/build
set out_dir    $script_dir/out

set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7z020clg400-1"}]
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]

puts "INFO: building for $part with $jobs jobs"

file mkdir $out_dir
file delete -force $build_dir

# Globals used by bd/ps7_config.tcl. fpgautil only reprograms the PL, so only
# the PS-PL interface settings matter.
set ::clk0_freq  125000000
set ::clk1_freq  250000000
set ::clk2_freq  50000000
set ::clk3_freq  200000000
set ::gpio_width 24
set ::bus_w_bit  "16 Bit"
set ::dram_w_bit "16 Bits"

create_project -force cordic_rp $build_dir -part $part

# ── Sources ──
add_files -norecurse [list \
  $repo_dir/src/atan_lut.v \
  $repo_dir/src/cordic.v \
  $repo_dir/src/cordic_top.v \
  $repo_dir/src/atanh_lut.v \
  $repo_dir/src/cordic_sqrt.v \
  $repo_dir/src/cordic_sqrt_wrapper.v \
  $script_dir/rtl/cordic_axi_regs.v \
  $script_dir/rtl/red_pitaya_cordic_top.v \
]
add_files -fileset constrs_1 -norecurse $script_dir/sdc/red_pitaya_cordic.xdc

# ── Block design ──
source $script_dir/bd/system.tcl
generate_target all [get_files system.bd]

set_property top red_pitaya_cordic_top [current_fileset]
update_compile_order -fileset sources_1

# ── Synthesis ──
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  error "ERROR: synthesis failed"
}

# ── Implementation ──
launch_runs impl_1 -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  error "ERROR: implementation failed"
}

open_run impl_1
report_utilization     -file $out_dir/utilization.rpt
report_utilization     -hierarchical -file $out_dir/utilization_hier.rpt
report_timing_summary  -max_paths 10 -file $out_dir/timing_summary.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "INFO: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
  error "ERROR: timing not met (WNS = $wns ns, WHS = $whs ns) — see out/timing_summary.rpt"
}

# ── Bitstream ──
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force $out_dir/cordic_rp.bit
write_cfgmem -force -format BIN -interface SMAPx32 -disablebitswap \
  -loadbit "up 0x0 $out_dir/cordic_rp.bit" -file $out_dir/cordic_rp.bit.bin

puts "INFO: done — $out_dir/cordic_rp.bit.bin"
