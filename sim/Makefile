# retro-z80 simulation
#
#   make            build and run every test written so far
#   make smoke      the tool-chain smoke test (sjasmplus, bin2hex, Icarus)
#   make vsmoke     the same test built with Verilator
#   make hello      the system: the boot ROM prints "hello" over USB serial,
#                   twice (the second time after the RESET control command)
#   make hello2mb   the same on a build for a 2 MB board (CHIPMB = 2): the
#                   self-test sees pages 0x100-0x1FF mirror 0x000-0x0FF
#   make systest    the system test ROM: system registers, I/O decode, SRAM
#                   bytes, writable boot ROM, the self-test, soft reset
#   make speeds     the speed test ROM: "hello" at every CPUSPEED setting,
#                   with the T-state rates measured
#   make lint       Verilator lint of the RTL (fpga/lint.sh)
#   make zexhello   the ZEX testbench's own checks: two tiny CP/M programs
#                   and the R register test
#   make zexdoc     ZEXDOC on the bare tv80 core in Verilator (long, see README)
#   make zexall     ZEXALL, the same with the undocumented flags (long)
#   make zexsyshello  the whole-system ZEX testbench's own checks (seconds)
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

.PHONY: all smoke vsmoke hello hello2mb systest speeds lint zexhello zexdoc zexall zexsyshello zexsys clean
all: smoke vsmoke hello hello2mb systest speeds zexhello

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
SYS_RTL   := $(addprefix $(RTL)/,z80_cpu.v cpu_cen.v bus_if.v mmu.v timebase.v dmac.v sram_ctl.v              bootrom.v fifo8.v serial.v sysregs.v retroz80.v)
SYS_SIM   := $(RTL)/platform/sim/oddr.v sram_model.v ft232h_model.v tb.v

$(BUILD)/boot.bin: $(ROOT)/firmware/boot/boot.asm $(ROOT)/firmware/boot/selftest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

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
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=boot.hex +hello +dma | tee hello.log
	@grep -q "^TEST PASSED" $(BUILD)/hello.log

hello2mb: $(BUILD)/tb2mb.vvp $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb2mb.vvp +rom=boot.hex +hello +dma | tee hello2mb.log
	@grep -q "^TEST PASSED" $(BUILD)/hello2mb.log

systest: $(BUILD)/tb.vvp $(BUILD)/systest.hex $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=systest.hex +dma | tee systest.log
	@grep -q "^TEST PASSED" $(BUILD)/systest.log

speeds: $(BUILD)/tb.vvp $(BUILD)/speeds.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=speeds.hex +speeds +dma +timeout=10000 | tee speeds.log
	@grep -q "^TEST PASSED" $(BUILD)/speeds.log

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
