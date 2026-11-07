# retro-z80 on the KS2: the SRAM tester's own constraints (issue #90), read
# after ks2.xdc, which has the SRAM pins (DRIVE 8, SLEW FAST, DQ pulled up,
# as the computer). The FT232H pins are the computer's (ks2_machine.xdc).

# ---- accelerator port: the FT232H
#   accel_io[7:0] D7-D0, [8] RXF#, [9] TXE#, [10] RD#, [11] WR#, [12] SIWU#
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {accel_io[0]}]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports {accel_io[1]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {accel_io[2]}]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {accel_io[3]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {accel_io[4]}]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {accel_io[5]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {accel_io[6]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {accel_io[7]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {accel_io[8]}]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports {accel_io[9]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {accel_io[10]}]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports {accel_io[11]}]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports {accel_io[12]}]
set_property DRIVE 4 [get_ports {accel_io[*]}]
set_property PULLUP true [get_ports {accel_io[*]}]

# ---- timing
# The FT232H is asynchronous (synchronised inside; its 245 timing is set by
# the design in 10 ns steps, spec 10)
set_false_path -from [get_ports {accel_io[*]}]
set_false_path -to   [get_ports {accel_io[*]}]

# The SRAM pins leave and enter through the I/O SERDES: their timing is what
# the tester measures, so they are not constrained. The three clocks come
# from one MMCM and are timed against each other as Vivado derives them
# (the 100 to 200 MHz gearbox in sramt_pads.v is an ordinary 5 ns path).
