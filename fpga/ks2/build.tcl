# retro-z80: Vivado build of the KS2 test pattern (non-project batch mode).
# Adapted from retro68k's fpga/ks3/build.tcl. Run through build.sh:
#   vivado -mode batch -source build.tcl -tclargs <repo root> <build dir>

set root   [file normalize [lindex $argv 0]]
set out    [file normalize [lindex $argv 1]]
set part   xc7a15tcsg324-1
set rtl    $root/fpga/rtl

cd $out
set_part $part

read_verilog [list \
    $root/fpga/ks2/top_ks2_pattern.v $rtl/tmds_encoder.v \
    $rtl/platform/artix7/ks2_clocks.v $rtl/platform/artix7/hdmi_out.v ]
read_xdc $root/fpga/ks2/ks2.xdc

synth_design -top top_ks2_pattern
write_checkpoint -force post_synth.dcp
report_utilization -file utilization_synth.txt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force post_route.dcp

report_utilization     -file utilization.txt
report_timing_summary  -file timing.txt -max_paths 20
report_clock_interaction -file clocks.txt
report_clocks          -file clock_list.txt
report_drc             -file drc.txt
report_io              -file io.txt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "retro-z80: worst setup slack $wns ns, worst hold slack $whs ns"

write_bitstream -force ks2_pattern.bit
# A raw image for the configuration flash (as a Next core, later; not used yet)
write_cfgmem -force -format bin -interface SPIx4 -size 16 \
    -loadbit "up 0x0 ks2_pattern.bit" -file ks2_pattern.bin

if {$wns < 0 || $whs < 0} {
    puts "retro-z80: TIMING NOT MET (see timing.txt)"
    exit 2
}
puts "retro-z80: build done, timing met"
