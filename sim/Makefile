# retro-z80 simulation
#
#   make            build and run every test written so far
#   make smoke      the tool-chain smoke test (sjasmplus, bin2hex, Icarus)
#   make vsmoke     the same test built with Verilator
#   make hello      the system: the boot ROM's self-test passes and it signs
#                   on over USB serial with the monitor's lines, twice (the
#                   second time after the RESET control command)
#   make hello2mb   the same on a build for a 2 MB board (CHIPMB = 2): the
#                   self-test sees pages 0x100-0x1FF mirror 0x000-0x0FF
#   make mon        the monitor (ticket #22) typed at over the serial link,
#                   in Verilator: a scripted session of every command, the
#                   RST calls, a breakpoint, a break and the trap (mon/)
#   make dis        the boot ROM's disassembler (ticket #23) on a table of
#                   every opcode, in the ZEX testbench, against a reference
#                   that sjasmplus checks (dis/; seconds)
#   make systest    the system test ROM: system registers, I/O decode, SRAM
#                   bytes, writable boot ROM, the self-test, soft reset
#   make intc       the interrupt controller on its own (sim/intc/tb_intc.v)
#   make inttest    the interrupt test ROM: IM 2 and IM 1, priority, INTENA,
#                   INTPEND/INTRAW, SOFTINT, VBLANK (one frame: a minute or so)
#   make nmitest    the NMI test ROM: the NMI pages, the stack capture, RETN,
#                   a written NMICAPPC, NMICTL.EN off, NMIMASK (seconds)
#   make dbg        the debug unit test ROM (ticket #28): registers, each
#                   breakpoint, the page match, single step of each
#                   instruction class at three speeds, /INT held off and
#                   STEPINT, watchpoints and the kept access; tb.v checks
#                   the requests' timing and counts each step (seconds)
#   make speeds     the speed test ROM: "hello" at every CPUSPEED setting,
#                   with the T-state rates measured
#   make failshow   the boot ROM built to report check 45 as failed: the
#                   screen shows it as 5 white stripes on red (60 ms of
#                   simulated time, a few minutes; not part of make all)
#   make vtest      the video test: L0 bitmaps and tile maps in bands of
#                   different settings (VTESTS=a t b), and the sprite screens
#                   (VTESTS=q s h), checked pixel by pixel against a Python
#                   model, in Verilator (about a minute a variant; not part
#                   of make all; CI runs s and h)
#   make boing      the sprite demo started from the monitor (F1), a frame
#                   of it grabbed (build/boing/boing.png; ten minutes)
#   make cop        the copper on its own (ticket #32): every instruction,
#                   reserved encoding and register, and the timing of WAITs
#                   and of its memory channel, against a model (cop/; in
#                   Verilator, about a minute)
#   make lint       Verilator lint of the RTL (fpga/lint.sh)
#   make zexhello   the ZEX testbench's own checks: two tiny CP/M programs
#                   and the R register test
#   make zexdoc     ZEXDOC on the bare tv80 core in Verilator (long, see README)
#   make zexall     ZEXALL, the same with the undocumented flags (long)
#   make zexsyshello  the whole-system ZEX testbench's own checks: hello must
#                   pass and bad must fail (seconds)
#   make zexsys     ZEXDOC on the whole system at 20 MHz (very long, see README)
#
# Needs: iverilog, verilator, sjasmplus, python3. Tools can be given
# explicitly: make SJASMPLUS=/path/sjasmplus IVERILOG=/path/iverilog

SJASMPLUS ?= sjasmplus
IVERILOG  ?= iverilog
VVP       ?= vvp
PYTHON    ?= python3
VERILATOR ?= verilator

# Verilator compiles its C++ with -Os by default. MSYS2's GCC 16.2 (UCRT64)
# fails to link -Os code in C++20 mode (undefined std::string move
# constructor), so build with -O2, which is also faster to run.
VL_OPT    := -MAKEFLAGS "OPT_FAST=-O2 OPT_SLOW=-O2 OPT_GLOBAL=-O2"
VL_FLAGS  := --binary -Wall -Wno-fatal $(VL_OPT)

ROOT  := ..
BUILD := build

.PHONY: all smoke vsmoke hello hello2mb mon dis systest intc inttest nmitest dbg speeds failshow vtest boing cop lint zexhello zexdoc zexall zexsyshello zexsys clean
all: smoke vsmoke hello hello2mb mon dis systest intc inttest nmitest dbg speeds cop zexhello zexsyshello

$(BUILD):
	mkdir -p $(BUILD)

# Tool-chain smoke test
$(BUILD)/smoke.bin: smoke/smoke.asm | $(BUILD)
	$(SJASMPLUS) --nologo --raw=$@ $<

$(BUILD)/smoke.hex: $(BUILD)/smoke.bin
	$(PYTHON) $(ROOT)/tools/bin2hex.py $< $@ 16

$(BUILD)/tb_smoke.vvp: smoke/tb_smoke.v | $(BUILD)
	$(IVERILOG) -g2005 -Wall -s tb_smoke -o $@ $<

smoke: $(BUILD)/tb_smoke.vvp $(BUILD)/smoke.hex
	cd $(BUILD) && $(VVP) -n tb_smoke.vvp | tee smoke.log
	@grep -q "^TEST PASSED" $(BUILD)/smoke.log

$(BUILD)/vl_smoke/vsmoke: smoke/tb_smoke.v | $(BUILD)
	$(VERILATOR) $(VL_FLAGS) --Mdir $(BUILD)/vl_smoke -o vsmoke $< > $(BUILD)/vl_smoke.log

vsmoke: $(BUILD)/vl_smoke/vsmoke $(BUILD)/smoke.hex
	cd $(BUILD) && ./vl_smoke/vsmoke | tee vsmoke.log
	@grep -q "^TEST PASSED" $(BUILD)/vsmoke.log

# The system (ticket #4): tv80 behind the bus interface, the scheduler and
# SRAM controller, the boot ROM, the system registers and USB serial, with
# retro68k's SRAM and FT232H models. Each run checks that the Z80 never
# waited (tb.v). +dma keeps the DMA port busy meanwhile.
RTL       := $(ROOT)/fpga/rtl
TV80      := $(ROOT)/fpga/third_party/tv80
INC       := $(ROOT)/firmware/include
TV80_CORE := $(addprefix $(TV80)/,tv80_core.v tv80_alu.v tv80_mcode.v tv80_reg.v)
SYS_RTL   := $(addprefix $(RTL)/,z80_cpu.v cpu_cen.v bus_if.v dbgunit.v mmu.v intpages.v timebase.v dmac.v sram_ctl.v              bootrom.v fifo8.v serial.v sysregs.v intc.v layer_pix.v bpldma.v sprites.v sprite_pix.v video.v copper.v retroz80.v timers.v ps2kb.v ps2map.v keys.v joy.v audio.v)
SYS_SIM   := $(RTL)/platform/sim/oddr.v sram_model.v ft232h_model.v ps2_model.v tb.v

BOOT_SRC  := $(addprefix $(ROOT)/firmware/boot/,boot.asm rom.inc console.asm keys.asm calls.asm monitor.asm \
                 selftest.asm tape.asm sprdemo.asm help.asm font.inc disasm.asm mondis.asm memtest.asm) $(INC)/hw.inc $(INC)/copper.inc

# The simulations' boot ROM looks for the start-up keys for 1 ms in place of
# 250 (KEYWAIT), which Icarus would take over an hour to get through
$(BUILD)/boot.bin: $(BOOT_SRC) | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) -DKEYWAIT=1 --raw=$@ $<

$(BUILD)/systest.bin: systest/systest.asm $(ROOT)/firmware/boot/selftest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) -I $(ROOT)/firmware/boot --raw=$@ $<

$(BUILD)/speeds.bin: speeds/speeds.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) $(ROOT)/tools/bin2hex.py $< $@

$(BUILD)/tb.vvp: $(TV80_CORE) $(SYS_RTL) $(SYS_SIM) $(RTL)/regmap.vh | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -DTV80_REFRESH -I $(RTL) -s tb -o $@ \
	    $(TV80_CORE) $(SYS_RTL) $(SYS_SIM)

# The same testbench for a 2 MB build (spec 2, section 11)
$(BUILD)/tb2mb.vvp: $(TV80_CORE) $(SYS_RTL) $(SYS_SIM) $(RTL)/regmap.vh | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -DTV80_REFRESH -I $(RTL) -s tb -Ptb.CHIPMB=2 -o $@ \
	    $(TV80_CORE) $(SYS_RTL) $(SYS_SIM)

hello: $(BUILD)/tb.vvp $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=boot.hex +hello +dma +timeout=40000 | tee hello.log
	@grep -q "^TEST PASSED" $(BUILD)/hello.log

# No +dma on the 2 MB build: the testbench's DMA area (0x380000 up) is
# mirrored onto the console and the monitor's workspace (0x1FC000 up)
hello2mb: $(BUILD)/tb2mb.vvp $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb2mb.vvp +rom=boot.hex +hello +timeout=40000 | tee hello2mb.log
	@grep -q "^TEST PASSED" $(BUILD)/hello2mb.log

systest: $(BUILD)/tb.vvp $(BUILD)/systest.hex $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=systest.hex +dma | tee systest.log
	@grep -q "^TEST PASSED" $(BUILD)/systest.log

# The interrupt controller on its own (ticket #16)
$(BUILD)/tb_intc.vvp: intc/tb_intc.v $(RTL)/intc.v $(RTL)/regmap.vh | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I $(RTL) -s tb_intc -o $@ intc/tb_intc.v $(RTL)/intc.v

intc: $(BUILD)/tb_intc.vvp
	cd $(BUILD) && $(VVP) -n tb_intc.vvp | tee intc.log
	@grep -q "^TEST PASSED" $(BUILD)/intc.log

$(BUILD)/inttest.bin: inttest/inttest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

inttest: $(BUILD)/tb.vvp $(BUILD)/inttest.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=inttest.hex +dma +timeout=40000 | tee inttest.log
	@grep -q "^TEST PASSED" $(BUILD)/inttest.log

# The NMI test ROM (ticket #27): the NMI set of the interrupt pages and the
# stack capture, with tb.v's model of the switch, the capture and RETN
$(BUILD)/nmitest.bin: nmitest/nmitest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

nmitest: $(BUILD)/tb.vvp $(BUILD)/nmitest.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=nmitest.hex +dma +timeout=2000 | tee nmitest.log
	@grep -q "^TEST PASSED" $(BUILD)/nmitest.log

# The debug unit test ROM (ticket #28; spec 18, section 11)
$(BUILD)/dbgtest.bin: dbg/dbgtest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

dbg: $(BUILD)/tb.vvp $(BUILD)/dbgtest.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=dbgtest.hex +dma +timeout=20000 | tee dbg.log
	@grep -q "^TEST PASSED" $(BUILD)/dbg.log

speeds: $(BUILD)/tb.vvp $(BUILD)/speeds.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=speeds.hex +speeds +dma +timeout=10000 | tee speeds.log
	@grep -q "^TEST PASSED" $(BUILD)/speeds.log

# The boot ROM's failure display (firmware/boot/boot.asm): check 45 reported
# as failed, shown as 5 white stripes; two frames must match
$(BUILD)/bootfail.bin: $(BOOT_SRC) | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) -DFAILTEST=0x45 -DKEYWAIT=1 --raw=$@ $<

failshow: $(BUILD)/tb.vvp $(BUILD)/bootfail.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=bootfail.hex +failshow=45 +timeout=70000 | tee failshow.log
	@grep -q "^TEST PASSED" $(BUILD)/failshow.log

# The system testbench in Verilator (--timing, so tb.v's delays and pixel
# clocks run as in Icarus), for the long video runs: about 20 times faster
# than Icarus (ticket #31)
VL_TB := $(BUILD)/vl_tb/vtb
$(VL_TB): $(TV80_CORE) $(SYS_RTL) $(SYS_SIM) $(RTL)/regmap.vh | $(BUILD)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal $(VL_OPT) -DTV80_REFRESH -I$(RTL) --top-module tb \
	    --Mdir $(BUILD)/vl_tb -o vtb $(TV80_CORE) $(SYS_RTL) $(SYS_SIM) > $(BUILD)/vl_tb.log

# The video test (spec 4, ticket #13): vtest/vgen.py makes bands of L0
# settings, a palette and random picture data; vtest/vtest.asm writes them,
# band by band, timed from each frame's start; tb.v logs the writes and grabs
# beam frame 1; vtest/vmodel.py replays the writes and checks every pixel.
# Variant a is a fixed set of bands, t tile maps, the others random. The
# sprite screens (ticket #31): s retro68k's spr screen, h the same with
# VIDCON.SHAREPAL, q a quick one (four sprites, set in the vertical blank
# only: the one to run locally). In the Verilator testbench, about a minute
# each (CI runs s and h); the variants run in parallel with make -j.
VTESTS ?= a t b
vtest: $(addprefix $(BUILD)/vtest_,$(addsuffix .ok,$(VTESTS)))

$(BUILD)/vtest_%.ok: $(VL_TB) vtest/vtest.asm vtest/vgen.py vtest/vmodel.py $(INC)/hw.inc
	@d=$(BUILD)/vtest_$*; rm -f $@; mkdir -p $$d; \
	$(PYTHON) vtest/vgen.py $* $$d && \
	$(SJASMPLUS) --nologo -I $(INC) -I $$d --raw=$$d/vtest.bin vtest/vtest.asm && \
	$(PYTHON) $(ROOT)/tools/bin2hex.py $$d/vtest.bin $$d/vtest.hex && \
	(cd $$d && ../vl_tb/vtb +rom=vtest.hex +ram=ram.hex +frame=1 +dma +timeout=60000 > sim.log); \
	grep -q "^TEST PASSED" $$d/sim.log || { tail -n 25 $$d/sim.log; exit 1; }; \
	$(PYTHON) vtest/vmodel.py $$d $$d/ram.hex 1 $$d/model.png && touch $@

# The sprite demo (ticket #31) from the monitor: F1 on the PS/2 keyboard,
# then a frame of it grabbed into build/boing/frame.ppm and boing.png. Ten
# minutes or so; not part of make all
boing: $(VL_TB) $(BUILD)/boot.hex
	@d=$(BUILD)/boing; mkdir -p $$d; cp $(BUILD)/boot.hex $$d/; \
	(cd $$d && ../vl_tb/vtb +rom=boot.hex +hello +boing +timeout=900000 > sim.log); \
	tail -n 20 $$d/sim.log; grep -q "^TEST PASSED" $$d/sim.log && \
	$(PYTHON) vtest/ppm2png.py $$d/frame.ppm $$d/boing.png

# The copper on its own (ticket #32): cop/tb_cop.v runs the lists of
# cop/coptest.asm on copper.v and the scheduler, cop/copcheck.py checks the
# log against its model of spec 6
COP_RTL := $(addprefix $(RTL)/,copper.v dmac.v timebase.v)
$(BUILD)/vl_cop/vcop: cop/tb_cop.v $(COP_RTL) $(RTL)/regmap.vh | $(BUILD)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal $(VL_OPT) -I$(RTL) --top-module tb_cop 	    --Mdir $(BUILD)/vl_cop -o vcop cop/tb_cop.v $(COP_RTL) > $(BUILD)/vl_cop.log

cop: $(BUILD)/vl_cop/vcop cop/coptest.asm cop/copcheck.py $(INC)/hw.inc $(INC)/copper.inc
	@d=$(BUILD)/cop; mkdir -p $$d; 	(cd $$d && $(SJASMPLUS) --nologo -I ../../$(INC) ../../cop/coptest.asm) && 	$(PYTHON) $(ROOT)/tools/bin2hex.py $$d/coptest.bin $$d/coptest.hex && 	$(PYTHON) $(ROOT)/tools/bin2hex.py $$d/cop_hi.bin $$d/cop_hi.hex && 	(cd $$d && ../vl_cop/vcop > sim.log); tail -n 5 $$d/sim.log; 	grep -q "^TEST PASSED" $$d/sim.log && 	$(PYTHON) cop/copcheck.py $$d/coptest.bin $$d/cop_hi.bin $$d/cop.log

lint:
	sh $(ROOT)/fpga/lint.sh

# ZEX: the bare tv80 core with 64 KB of RAM runs CP/M .COM programs (ticket #2)
TV80_SRC := $(addprefix $(TV80)/,tv80s.v tv80_core.v tv80_alu.v tv80_mcode.v tv80_reg.v)
ZEX_RUN   = cd $(BUILD) && ./vl_zex/vzex +cpm=cpm.bin

$(BUILD)/cpm.bin: zex/cpm.asm | $(BUILD)
	$(SJASMPLUS) --nologo --raw=$@ $<

$(BUILD)/%.com: zex/%.asm | $(BUILD)
	$(SJASMPLUS) --nologo --raw=$@ $<

# A C++ main gives the clock (faster than --binary's timing scheduler)
$(BUILD)/vl_zex/vzex: zex/tb_zex.v $(CURDIR)/zex/zex_main.cpp $(TV80_SRC) | $(BUILD)
	$(VERILATOR) --cc --exe --build -Wall -Wno-fatal $(VL_OPT) -DTV80_REFRESH \
	    --x-assign fast --x-initial fast --top-module tb_zex \
	    --Mdir $(BUILD)/vl_zex -o vzex zex/tb_zex.v $(CURDIR)/zex/zex_main.cpp $(TV80_SRC) \
	    > $(BUILD)/vl_zex.log

ZEX_DEPS := $(BUILD)/vl_zex/vzex $(BUILD)/cpm.bin

zexhello: $(ZEX_DEPS) $(BUILD)/hello.com $(BUILD)/bad.com $(BUILD)/rtest.com
	$(ZEX_RUN) +com=hello.com +tests=2 +maxcycles=100000 | tee zexhello.log
	@grep -q "^TEST PASSED" $(BUILD)/zexhello.log
	$(ZEX_RUN) +com=bad.com +tests=2 +maxcycles=100000 | tee zexbad.log
	@grep -q "^TEST FAILED" $(BUILD)/zexbad.log
	$(ZEX_RUN) +com=rtest.com +tests=5 +maxcycles=100000 | tee zexr.log
	@grep -q "^TEST PASSED" $(BUILD)/zexr.log

# The disassembler (ticket #23): disref.py makes a table of every opcode and
# the text it must give; sjasmplus checks that text gives the table's bytes;
# distest.com runs the ROM's disasm.asm on the table on the bare core
$(BUILD)/distab.bin: dis/disref.py | $(BUILD)
	$(PYTHON) dis/disref.py make $(BUILD)
	$(SJASMPLUS) --nologo --raw=$(BUILD)/dis_sj.bin $(BUILD)/dis_sj.asm > $(BUILD)/dis_sj.log
	$(PYTHON) dis/disref.py sj $(BUILD)

$(BUILD)/distest.com: dis/distest.asm $(ROOT)/firmware/boot/disasm.asm $(BUILD)/distab.bin
	$(SJASMPLUS) --nologo -I $(ROOT)/firmware/boot -I $(BUILD) --raw=$@ $<

dis: $(ZEX_DEPS) $(BUILD)/distest.com
	$(ZEX_RUN) +com=distest.com +tests=1 +maxcycles=100000000 > dis.out; tail -n 2 dis.out
	$(PYTHON) dis/disref.py check $(BUILD) | tee $(BUILD)/dis.result
	@grep -q "^TEST PASSED" $(BUILD)/dis.result

# ZEXDOC and ZEXALL: each of the 67 tests runs as its own process (+only=K),
# ZEX_JOBS at a time; then the results are collected into build/zexdoc.log
# (or zexall.log). Serially they take about 3 hours.
ZEX_TESTS := $(shell seq 0 66)
ZEX_JOBS  ?= $(shell nproc)

zexdoc zexall: $(ZEX_DEPS)
	rm -rf $(BUILD)/$@
	mkdir -p $(BUILD)/$@
	$(MAKE) -j$(ZEX_JOBS) --no-print-directory \
	    $(patsubst %,$(BUILD)/$@/%.log,$(ZEX_TESTS))
	@cd $(BUILD) && for k in $(ZEX_TESTS); do \
	    grep -E "  (OK|ERROR)" $@/$$k.log | sed "s/^/$$k /" ; \
	    grep "clocks" $@/$$k.log | sed "s/^/    /" ; \
	done > $@.log; \
	n=$$(grep -l "^TEST PASSED" $@/*.log | wc -l); \
	if [ $$n -eq 67 ]; then r="TEST PASSED"; else r="TEST FAILED: $$n of 67 tests OK"; fi; \
	echo "$$r" >> $@.log; cat $@.log
	@grep -q "^TEST PASSED" $(BUILD)/$@.log

$(BUILD)/zexdoc/%.log $(BUILD)/zexall/%.log:
	cd $(BUILD) && ./vl_zex/vzex +cpm=cpm.bin +com=../zex/$(notdir $(@D)).com \
	    +tests=1 +only=$* > $(notdir $(@D))/$*.log

# ZEXDOC on the whole system (ticket #7): tv80 behind the bus interface, the
# MMU, the scheduler and SRAM controller, with a cycle model of the SRAM, at
# 20 MHz. A loader in the boot ROM (zexboot.asm) maps SRAM pages 0-7 flat and
# jumps to the program, which the testbench has put in SRAM with page zero
# and a BDOS (cpm.asm, console on reserved port 0x01). Every run checks that
# the Z80 never waited. +dma keeps the DMA port busy meanwhile.
ZEXSYS_RUN = cd $(BUILD) && ./vl_zexsys/vzexsys +cpm=cpmsys.bin

$(BUILD)/cpmsys.bin: zex/cpm.asm | $(BUILD)
	$(SJASMPLUS) --nologo -DCONSOLE=0x01 --raw=$@ $<

$(BUILD)/zexboot.bin: zex/zexboot.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

$(BUILD)/vl_zexsys/vzexsys: zex/tb_zexsys.v $(CURDIR)/zex/zexsys_main.cpp $(TV80_CORE) $(SYS_RTL) $(RTL)/regmap.vh | $(BUILD)
	$(VERILATOR) --cc --exe --build -Wall -Wno-fatal $(VL_OPT) -DTV80_REFRESH -I$(RTL) 	    --x-assign fast --x-initial fast --top-module tb_zexsys 	    --Mdir $(BUILD)/vl_zexsys -o vzexsys zex/tb_zexsys.v $(CURDIR)/zex/zexsys_main.cpp 	    $(TV80_CORE) $(SYS_RTL) > $(BUILD)/vl_zexsys.log

ZEXSYS_DEPS := $(BUILD)/vl_zexsys/vzexsys $(BUILD)/cpmsys.bin $(BUILD)/zexboot.hex

zexsyshello: $(ZEXSYS_DEPS) $(BUILD)/hello.com $(BUILD)/bad.com
	$(ZEXSYS_RUN) +com=hello.com +tests=2 +dma +maxcycles=1000000 | tee zexsyshello.log
	@grep -q "^TEST PASSED" $(BUILD)/zexsyshello.log
	$(ZEXSYS_RUN) +com=bad.com +tests=2 +dma +maxcycles=1000000 | tee zexsysbad.log
	@grep -q "^TEST FAILED" $(BUILD)/zexsysbad.log

# Each of ZEXDOC's 67 tests as its own process, as zexdoc above
zexsys: $(ZEXSYS_DEPS)
	rm -rf $(BUILD)/$@
	mkdir -p $(BUILD)/$@
	$(MAKE) -j$(ZEX_JOBS) --no-print-directory 	    $(patsubst %,$(BUILD)/$@/%.log,$(ZEX_TESTS))
	@cd $(BUILD) && for k in $(ZEX_TESTS); do 	    grep -E "  (OK|ERROR)" $@/$$k.log | sed "s/^/$$k /" ; 	    grep -E "T-states|never waited" $@/$$k.log | sed "s/^/    /" ; 	done > $@.log; 	n=$$(grep -l "^TEST PASSED" $@/*.log | wc -l); 	if [ $$n -eq 67 ]; then r="TEST PASSED"; else r="TEST FAILED: $$n of 67 tests OK"; fi; 	echo "$$r" >> $@.log; cat $@.log
	@grep -q "^TEST PASSED" $(BUILD)/$@.log

$(BUILD)/zexsys/%.log:
	$(ZEXSYS_RUN) +com=../zex/zexdoc.com +tests=1 +only=$* +dma > zexsys/$*.log

clean:
	rm -rf $(BUILD)

# ---- Timers and watchdog (ticket #17)
#   make timers     the timers on their own (sim/timers/tb_timers.v): every
#                   source's rate to the clock, chaining, one-shot, reload,
#                   the requests, the capture path, the watchdog
#   make timertest  the timer test ROM on the machine (about 25 ms simulated)
.PHONY: timers timertest
all: timers timertest

$(BUILD)/tb_timers.vvp: timers/tb_timers.v $(RTL)/timers.v $(RTL)/regmap.vh | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I $(RTL) -s tb_timers -o $@ timers/tb_timers.v $(RTL)/timers.v

timers: $(BUILD)/tb_timers.vvp
	cd $(BUILD) && $(VVP) -n tb_timers.vvp | tee timers.log
	@grep -q "^TEST PASSED" $(BUILD)/timers.log

$(BUILD)/timertest.bin: timertest/timertest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

timertest: $(BUILD)/tb.vvp $(BUILD)/timertest.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=timertest.hex +dma +timeout=40000 | tee timertest.log
	@grep -q "^TEST PASSED" $(BUILD)/timertest.log

# ---- Input (ticket #19)
#   make bootkeys   the monitor typed at on the keyboards (tb.v +keys): PS/2
#                   keys and a membrane key, echoed back over the serial link
#                   as a command line (about 30 ms simulated, ten minutes;
#                   not part of make all)
#   make input      the input units on their own (sim/input/tb_input.v): the
#                   PS/2 keyboard against a keyboard model (FIFO, flags,
#                   sending, timeout), the PS/2 to port 0xFE mapper, the
#                   membrane scan, KEYMAP, KEYROW and port 0xFE rows, the
#                   joysticks with Atari and Mega Drive pad models, Kempston
.PHONY: input bootkeys
all: input

$(BUILD)/tb_input.vvp: input/tb_input.v ps2_model.v $(addprefix $(RTL)/,ps2kb.v ps2map.v keys.v joy.v regmap.vh) | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I $(RTL) -s tb_input -o $@ input/tb_input.v ps2_model.v \
	    $(addprefix $(RTL)/,ps2kb.v ps2map.v keys.v joy.v)

input: $(BUILD)/tb_input.vvp
	cd $(BUILD) && $(VVP) -n tb_input.vvp | tee input.log
	@grep -q "^TEST PASSED" $(BUILD)/input.log

bootkeys: $(BUILD)/tb.vvp $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=boot.hex +hello +keys +timeout=150000 | tee bootkeys.log
	@grep -q "^TEST PASSED" $(BUILD)/bootkeys.log

# ---- Port 0xFE writes (ticket #21)
#   make fe         the border and the beeper on their own (sim/fe/tb_fe.v):
#                   mid-line border changes 7-60 ns after the write, BGCOLOR
#                   read back and its line rule kept, the beeper's sigma-delta
#                   streams at a quarter of full scale
.PHONY: fe
all: fe

$(BUILD)/tb_fe.vvp: fe/tb_fe.v $(addprefix $(RTL)/,video.v layer_pix.v bpldma.v sprites.v sprite_pix.v audio.v regmap.vh) | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I $(RTL) -s tb_fe -o $@ fe/tb_fe.v \
	    $(addprefix $(RTL)/,video.v layer_pix.v bpldma.v sprites.v sprite_pix.v audio.v)

fe: $(BUILD)/tb_fe.vvp
	cd $(BUILD) && $(VVP) -n tb_fe.vvp | tee fe.log
	@grep -q "^TEST PASSED" $(BUILD)/fe.log

# ---- The monitor (ticket #22): tb_mon.v types mon/check.py's session over
# the serial link in Verilator; check.py compares what came back
$(BUILD)/mon_rom.bin: $(BOOT_SRC) | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) -DKEYWAIT=1 --raw=$@ $<

$(BUILD)/vl_mon/vmon: mon/tb_mon.v $(CURDIR)/mon/mon_main.cpp $(TV80_CORE) $(SYS_RTL) $(RTL)/regmap.vh | $(BUILD)
	$(VERILATOR) --cc --exe --build -Wall -Wno-fatal $(VL_OPT) -DTV80_REFRESH -I$(RTL) \
	    --x-assign fast --x-initial fast --top-module tb_mon \
	    --Mdir $(BUILD)/vl_mon -o vmon mon/tb_mon.v $(CURDIR)/mon/mon_main.cpp \
	    $(TV80_CORE) $(SYS_RTL) > $(BUILD)/vl_mon.log

mon: $(BUILD)/vl_mon/vmon $(BUILD)/mon_rom.hex mon/check.py
	$(PYTHON) mon/check.py make $(BUILD)
	cd $(BUILD) && ./vl_mon/vmon +session=session.in > mon.out; tail -n 2 mon.out
	$(PYTHON) mon/check.py check $(BUILD) | tee $(BUILD)/mon.result
	@grep -q "^TEST PASSED" $(BUILD)/mon.result
