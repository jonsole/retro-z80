# retro-z80 on the KS2: the computer's SRAM at 20 ns cycles (sram_ctl.v and
# top_ks2.v's flip-flop and ODDR pads), read after ks2_machine.xdc. Every
# build of the computer but the fast-memory one (issue #91).

# SRAM read data: captured in the input pad flip-flops (sram_ctl.v)
set_property IOB TRUE [get_cells -hier -filter {NAME =~ sys/mem/rdata_reg*}]
