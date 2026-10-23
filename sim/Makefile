# retro-z80 simulation
#
#   make            build and run every test written so far
#   make smoke      the tool-chain smoke test (sjasmplus, bin2hex, Icarus)
#   make vsmoke     the same test built with Verilator
#   make zexhello   the ZEX testbench's own check: two tiny CP/M programs
#   make zexdoc     ZEXDOC on the bare tv80 core in Verilator (long, see README)
#   make zexall     ZEXALL, the same with the undocumented flags (long)
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

.PHONY: all smoke vsmoke zexhello zexdoc zexall clean
all: smoke vsmoke zexhello

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

# ZEX: the bare tv80 core with 64 KB of RAM runs CP/M .COM programs (ticket #2)
TV80     := $(ROOT)/fpga/third_party/tv80
TV80_SRC := $(addprefix $(TV80)/,tv80s.v tv80_core.v tv80_alu.v tv80_mcode.v tv80_reg.v)
ZEX_RUN   = cd $(BUILD) && ./vl_zex/vzex +cpm=cpm.bin

$(BUILD)/cpm.bin: zex/cpm.asm | $(BUILD)
	$(SJASMPLUS) --nologo --raw=$@ $<

$(BUILD)/%.com: zex/%.asm | $(BUILD)
	$(SJASMPLUS) --nologo --raw=$@ $<

# A C++ main gives the clock (faster than --binary's timing scheduler)
$(BUILD)/vl_zex/vzex: zex/tb_zex.v zex/zex_main.cpp $(TV80_SRC) | $(BUILD)
	$(VERILATOR) --cc --exe --build -Wall -Wno-fatal $(VL_OPT) -DTV80_REFRESH \
	    --x-assign fast --x-initial fast --top-module tb_zex \
	    --Mdir $(BUILD)/vl_zex -o vzex zex/tb_zex.v zex/zex_main.cpp $(TV80_SRC) \
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

clean:
	rm -rf $(BUILD)
