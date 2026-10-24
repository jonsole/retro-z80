# retro-z80 on the ZX Spectrum Next KS2 (issue 4): XC7A15T-1CSG324
# Pin locations, I/O standards and drive from the Next's own
# zxnext_pins_issue4.xdc (https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA,
# cores/zxnext/src), as are the configuration settings. Only the pins the
# test pattern build uses or holds are listed; the rest are pulled up.

# ---- configuration, as the Next's (SPI flash, 4 bits wide, 32-bit addresses)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 40 [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK DISABLE [current_design]
set_property BITSTREAM.CONFIG.NEXT_CONFIG_REBOOT DISABLE [current_design]
set_property BITSTREAM.CONFIG.INITPIN PULLNONE [current_design]
set_property BITSTREAM.CONFIG.M0PIN PULLNONE [current_design]
set_property BITSTREAM.CONFIG.M1PIN PULLNONE [current_design]
set_property BITSTREAM.CONFIG.M2PIN PULLNONE [current_design]
set_property BITSTREAM.CONFIG.PROGPIN PULLNONE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# ---- clock
set_property -dict {PACKAGE_PIN T5 IOSTANDARD LVCMOS33} [get_ports clock_50_i]

# ---- VGA: 3 bits per colour through resistors (no DAC), syncs
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[0]}]
set_property -dict {PACKAGE_PIN K5 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[1]}]
set_property -dict {PACKAGE_PIN K3 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[2]}]
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[0]}]
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[1]}]
set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[2]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[0]}]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[1]}]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[2]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports hsync_o]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports vsync_o]
set_property DRIVE 8 [get_ports {rgb_r_o[*] rgb_g_o[*] rgb_b_o[*] hsync_o vsync_o}]

# ---- HDMI: TMDS pairs 0 blue, 1 green, 2 red, 3 clock (the N pins follow)
set_property -dict {PACKAGE_PIN E6 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[0]}]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[1]}]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[2]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[3]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_n_o[*]}]

# ---- SRAM (IS61WV102416FBLL, 1M x 16): held deselected
set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[0]}]
set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[1]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[2]}]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[3]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[4]}]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[5]}]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[6]}]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[7]}]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[8]}]
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[9]}]
set_property -dict {PACKAGE_PIN P4 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[10]}]
set_property -dict {PACKAGE_PIN N4 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[11]}]
set_property -dict {PACKAGE_PIN P5 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[12]}]
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[13]}]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[14]}]
set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[15]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[16]}]
set_property -dict {PACKAGE_PIN P2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[17]}]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[18]}]
set_property -dict {PACKAGE_PIN R5 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[19]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[0]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[1]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[2]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[3]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[4]}]
set_property -dict {PACKAGE_PIN V1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[5]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[6]}]
set_property -dict {PACKAGE_PIN M3 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[7]}]
set_property -dict {PACKAGE_PIN D3 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[8]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[9]}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[10]}]
set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[11]}]
set_property -dict {PACKAGE_PIN U9 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[12]}]
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[13]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[14]}]
set_property -dict {PACKAGE_PIN U3 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[15]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports ram_oe_n_o]
set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVCMOS33} [get_ports ram_we_n_o]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports ram_cs_n_o]
set_property -dict {PACKAGE_PIN F5 IOSTANDARD LVCMOS33} [get_ports ram_lb_n_o]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports ram_ub_n_o]
set_property -dict {DRIVE 8 SLEW FAST} [get_ports {ram_addr_o[*] ram_data_io[*] ram_oe_n_o ram_we_n_o ram_cs_n_o ram_lb_n_o ram_ub_n_o}]
set_property PULLUP true [get_ports {ram_data_io[*]}]

# ---- configuration flash, SD cards: deselected
set_property -dict {PACKAGE_PIN L13 IOSTANDARD LVCMOS33 DRIVE 4} [get_ports flash_cs_n_o]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVTTL DRIVE 4} [get_ports sd_cs0_n_o]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVTTL DRIVE 4} [get_ports sd_cs1_n_o]

# ---- audio, joystick select, keyboard rows, expansion bus RAMCS
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33 DRIVE 16} [get_ports audioext_l_o]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33 DRIVE 16} [get_ports audioext_r_o]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports audioint_o]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33 DRIVE 4} [get_ports mic_port_o]
set_property OFFCHIP_TERM NONE [get_ports {audioext_l_o audioext_r_o}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVTTL DRIVE 4} [get_ports joysel_o]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[0]}]
set_property -dict {PACKAGE_PIN M16 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[1]}]
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[2]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[3]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[4]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[5]}]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[6]}]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVTTL DRIVE 4 PULLUP true} [get_ports {keyb_row_o[7]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33 DRIVE 4 PULLDOWN true} [get_ports bus_ramcs_io]

# ---- clocks
create_clock -name clk50 -period 20.000 [get_ports clock_50_i]

# The pixel clocks (MMCM 2, 576p) and the system clock (MMCM 1) come from the
# same oscillator but have no designed phase relation: the only signal between
# them, the heartbeat, goes through a two-flip-flop synchroniser
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins clocks/mmcm_sys/CLKOUT*]] \
    -group [get_clocks -of_objects [get_pins clocks/mmcm_pix/CLKOUT*]]

