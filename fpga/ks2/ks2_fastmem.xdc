# retro-z80 on the KS2: the fast-memory experiment's SRAM (issue #91;
# sram_ctl8.v on the SERDES pads, sram8_pads.v), read after ks2_machine.xdc
# in place of ks2_sram20.xdc.

# The SRAM pins leave and enter through the I/O SERDES, as in the SRAM
# tester (ks2_sramtest.xdc): their timing is set in 1.25 ns steps by the
# design and was measured on the board (docs/notes/sram-ks2.md), so they
# are not constrained. The 400, 200 and 100 MHz clocks come from one MMCM
# and are timed against each other as Vivado derives them: the gearbox in
# sram8_pads.v is a 5 ns path from 100 to 200 MHz, and the read data a
# 10 ns path from the ISERDESE2s (on the 100 MHz CLKDIV) to the units.

# The ISERDESE2s take 400 MHz on CLK and 100 MHz on CLKDIV, which must keep
# their phase. phys_opt_design otherwise puts a second BUFG in front of the
# 100 MHz one, to clock a few DMA engine registers early (DRC REQP-1580), so
# the SERDES clock nets are left alone and kept as one delay group.
set_property DONT_TOUCH true [get_cells {clocks/b0 clocks/g_serdes.b1 clocks/g_serdes.b4}]
set_property DONT_TOUCH true [get_nets -of [get_pins {clocks/b0/O clocks/b0/I}]]
set_property CLOCK_DELAY_GROUP fm_sram_clocks [get_nets -of [get_pins {clocks/b0/O clocks/g_serdes.b1/O clocks/g_serdes.b4/O}]]
