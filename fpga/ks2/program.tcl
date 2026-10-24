# Load a bitstream straight into the KS2's FPGA over JTAG (the flash is not
# touched). From retro68k's fpga/ks3/program.tcl, for the XC7A15T.
#   vivado -mode batch -source program.tcl -tclargs <bitfile>
set bit [lindex $argv 0]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a15t*] 0]
if {$dev eq ""} {
    puts "retro-z80: no XC7A15T on the JTAG chain (found: [get_hw_devices])"
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "retro-z80: FPGA loaded"
close_hw_manager
