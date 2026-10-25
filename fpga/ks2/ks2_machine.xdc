# retro-z80 on the KS2: the computer's own constraints (issue #11), read
# after ks2.xdc, which has the pins both KS2 builds share. Pins from the
# Next's zxnext_pins_issue4.xdc; timing after retro68k's ks3.xdc.

# ---- buttons (active low, pulled up)
set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33 PULLUP true} [get_ports btn_reset_n_i]
set_property -dict {PACKAGE_PIN T8 IOSTANDARD LVCMOS33 PULLUP true} [get_ports btn_multiface_n_i]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33 PULLUP true} [get_ports btn_divmmc_n_i]

# ---- accelerator port: the FT232H (provisional, as retro68k's KS3 build;
# spec 10, open point U2). The KS2 (issue 4) and KS3 (issue 5) put
# accel_io[12:0] on the same FPGA pins.
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
set_property PULLUP true [get_ports {accel_io[*]}]      ;# RXF# and TXE# read 'not ready' with no module

# ---- input (issue #19, spec 12), from the Next's zxnext_pins_issue4.xdc.
# The keyboard rows (open drain, pulled up) and joysel_o are in ks2.xdc.
# PS/2 keyboard: open collector, pulled up (the Next: DRIVE 16, no
# termination)
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33 DRIVE 16 PULLUP true} [get_ports ps2_clk_io]
set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVCMOS33 DRIVE 16 PULLUP true} [get_ports ps2_data_io]
set_property OFFCHIP_TERM NONE [get_ports {ps2_clk_io ps2_data_io}]
# Membrane columns, pulled up (low = a key in the driven row)
set_property -dict {PACKAGE_PIN R8  IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[0]}]
set_property -dict {PACKAGE_PIN R7  IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[1]}]
set_property -dict {PACKAGE_PIN T6  IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[2]}]
set_property -dict {PACKAGE_PIN V7  IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[3]}]
set_property -dict {PACKAGE_PIN U6  IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[4]}]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[5]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVTTL PULLUP true} [get_ports {keyb_col_i[6]}]
# Joysticks: the multiplexer's outputs (active low; weak pull-ups added
# here, the Next has none) and pin 7, the Mega Drive select
set_property -dict {PACKAGE_PIN T13 IOSTANDARD LVTTL PULLUP true} [get_ports joyp1_i]
set_property -dict {PACKAGE_PIN R12 IOSTANDARD LVTTL PULLUP true} [get_ports joyp2_i]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVTTL PULLUP true} [get_ports joyp3_i]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVTTL PULLUP true} [get_ports joyp4_i]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVTTL PULLUP true} [get_ports joyp6_i]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVTTL PULLUP true} [get_ports joyp9_i]
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVTTL DRIVE 4} [get_ports joyp7_o]

# ---- timing
# Buttons and the FT232H are asynchronous (synchronised inside; the 245 FIFO
# interface's timing is set by the design in 10 ns steps, spec 10)
set_false_path -from [get_ports {btn_reset_n_i btn_multiface_n_i btn_divmmc_n_i}]
set_false_path -from [get_ports {accel_io[*]}]
set_false_path -to   [get_ports {accel_io[*]}]
# The input lines are slow and synchronised inside (spec 12)
set_false_path -from [get_ports {ps2_clk_io ps2_data_io keyb_col_i[*] joyp1_i joyp2_i joyp3_i joyp4_i joyp6_i joyp9_i}]
set_false_path -to   [get_ports {ps2_clk_io ps2_data_io keyb_row_o[*] joyp7_o joysel_o}]

# The settings the pixel side copies (BGCOLOR once a line, VIDCON.EN through
# two flip-flops) are covered by the asynchronous clock groups in ks2.xdc.

# SRAM read data: captured in the input pad flip-flops (sram_ctl.v)
set_property IOB TRUE [get_cells -hier -filter {NAME =~ sys/mem/rdata_reg*}]

# tv80: every register in the CPU (the core and z80_cpu.v's strobes and read
# data register) is enabled by cen, and cen pulses are at least 5 clocks
# apart, so paths from one of them to another have 5 clocks (spec 1,
# section 3.3; open point B1)
set cpu_regs [get_cells -hier -filter {NAME =~ sys/cpu/* && IS_SEQUENTIAL}]
set_multicycle_path -setup 5 -from $cpu_regs -to $cpu_regs
set_multicycle_path -hold  4 -from $cpu_regs -to $cpu_regs
