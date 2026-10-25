# retro-z80 tools: register map checks, and the debug bridge's tests
#
#   make check      regmap.py --verify, its self-test, and the generated headers
#                   assembled (sjasmplus), compiled (C), simulated (Icarus) and
#                   linted (Verilator, WIDTHTRUNC as an error, as retro68k);
#                   then the bridge's tests (bridge)
#   make bridge     the debug bridge and rlink.py against the stub model (Python only)
#   make regmap     rewrite the generated files from fpga/regmap.def
#
# Needs: python3, sjasmplus, a C compiler (cc), iverilog and verilator. Tools can be given
# explicitly: make check SJASMPLUS=/path/sjasmplus CC=gcc IVERILOG=/path/iverilog

PYTHON    ?= python3
SJASMPLUS ?= sjasmplus
IVERILOG  ?= iverilog
VERILATOR ?= verilator
VVP       ?= vvp
CC        ?= cc

ROOT  := ..
INC   := $(ROOT)/firmware/include
RTL   := $(ROOT)/fpga/rtl
BUILD := build

.PHONY: check regmap verify selftest asm c verilog bridge clean
check: verify selftest asm c verilog bridge

regmap:
	$(PYTHON) regmap.py

verify:
	$(PYTHON) regmap.py --verify

selftest:
	$(PYTHON) test/test_regmap.py

$(BUILD):
	mkdir -p $(BUILD)

asm: | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$(BUILD)/hw_test.bin test/hw_test.asm

c: | $(BUILD)
	$(CC) -std=c11 -Wall -Wextra -Werror -I $(INC) -o $(BUILD)/hw_test test/hw_test.c

verilog: | $(BUILD)
	$(VERILATOR) --lint-only --default-language 1364-2005 -Wall -Wno-fatal -Werror-WIDTHTRUNC -I$(RTL) test/regmap_test.v
	$(IVERILOG) -g2005 -Wall -I $(RTL) -s regmap_test -o $(BUILD)/regmap_test.vvp test/regmap_test.v
	$(VVP) -n $(BUILD)/regmap_test.vvp | tee $(BUILD)/regmap_test.log
	@grep -q "^TEST PASSED" $(BUILD)/regmap_test.log

bridge:
	$(PYTHON) test/test_bridge.py

clean:
	rm -rf $(BUILD)
