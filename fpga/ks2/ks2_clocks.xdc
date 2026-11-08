# retro-z80 on the KS2: the clocks of ks2_clocks.v, for the builds that use
# it (the computer and the test pattern), read after ks2.xdc.

# The pixel clocks (MMCM 2, 576p) and the system clock (MMCM 1) come from the
# same oscillator but have no designed phase relation: every signal between
# them goes through a synchroniser (the pattern's heartbeat; VIDCON.EN, the
# start of a frame, resets) or is a setting that only changes between lines
# (BGCOLOR) or is sampled until two samples agree (the beam line; spec 4,
# section 3.1)
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins clocks/mmcm_sys/CLKOUT*]] \
    -group [get_clocks -of_objects [get_pins clocks/mmcm_pix/CLKOUT*]]

