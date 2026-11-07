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
