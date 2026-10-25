# retro-z80: Vivado builds for the KS2 (non-project batch mode).
# Adapted from retro68k's fpga/ks3/build.tcl. Run through build.sh:
#   vivado -mode batch -source build.tcl -tclargs <repo root> <build dir> <what>
# <what> is "machine" (the computer, top_ks2; build.sh has put boot.hex in
# the build folder) or "pattern" (the test pattern, top_ks2_pattern).

set root   [file normalize [lindex $argv 0]]
set out    [file normalize [lindex $argv 1]]
set what   [lindex $argv 2]
set part   xc7a15tcsg324-1
set rtl    $root/fpga/rtl

cd $out
set_part $part

if {$what eq "pattern"} {
    set top  top_ks2_pattern
    set name ks2_pattern
    read_verilog [list \
        $root/fpga/ks2/top_ks2_pattern.v $rtl/tmds_encoder.v \
        $rtl/platform/artix7/ks2_clocks.v $rtl/platform/artix7/hdmi_out.v ]
    read_xdc $root/fpga/ks2/ks2.xdc
} else {
    set top  top_ks2
    set name retroz80_ks2
    read_verilog [list \
        $root/fpga/third_party/tv80/tv80_core.v $root/fpga/third_party/tv80/tv80_alu.v \
        $root/fpga/third_party/tv80/tv80_mcode.v $root/fpga/third_party/tv80/tv80_reg.v \
        $rtl/z80_cpu.v $rtl/cpu_cen.v $rtl/bus_if.v $rtl/dbgunit.v $rtl/mmu.v $rtl/intpages.v $rtl/timebase.v $rtl/dmac.v \
        $rtl/sram_ctl.v $rtl/bootrom.v $rtl/fifo8.v $rtl/serial.v $rtl/sysregs.v $rtl/intc.v $rtl/layer_pix.v $rtl/bpldma.v $rtl/video.v $rtl/timers.v \
        $rtl/ps2kb.v $rtl/ps2map.v $rtl/keys.v $rtl/joy.v $rtl/audio.v \
        $rtl/retroz80.v $rtl/tmds_encoder.v $root/fpga/ks2/top_ks2.v \
        $rtl/platform/artix7/ks2_clocks.v $rtl/platform/artix7/hdmi_out.v \
        $rtl/platform/artix7/oddr.v ]
    read_xdc $root/fpga/ks2/ks2.xdc
    read_xdc $root/fpga/ks2/ks2_machine.xdc
}

# tv80 counts R and drives rfsh_n only with TV80_REFRESH (spec 1)
synth_design -top $top -include_dirs $rtl -verilog_define TV80_REFRESH
write_checkpoint -force post_synth.dcp
report_utilization -file utilization_synth.txt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force post_route.dcp

report_utilization     -file utilization.txt
report_utilization     -hierarchical -file utilization_hier.txt
report_timing_summary  -file timing.txt -max_paths 20
report_clock_interaction -file clocks.txt
report_clocks          -file clock_list.txt
report_drc             -file drc.txt
report_io              -file io.txt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "retro-z80: worst setup slack $wns ns, worst hold slack $whs ns"

write_bitstream -force $name.bit
# A raw image for the configuration flash (as a Next core, later; not used yet)
write_cfgmem -force -format bin -interface SPIx4 -size 16 \
    -loadbit "up 0x0 $name.bit" -file $name.bin

if {$wns < 0 || $whs < 0} {
    puts "retro-z80: TIMING NOT MET (see timing.txt)"
    exit 2
}
puts "retro-z80: build done, timing met"
