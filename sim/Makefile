# retro-z80 simulation
#
#   make            build and run every test written so far
#   make smoke      the tool-chain smoke test (sjasmplus, bin2hex, Icarus)
#   make vsmoke     the same test built with Verilator
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

.PHONY: all smoke vsmoke clean
all: smoke vsmoke

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

clean:
	rm -rf $(BUILD)
