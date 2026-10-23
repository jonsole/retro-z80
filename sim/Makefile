# retro-z80 simulation
#
#   make            build and run every test written so far
#   make smoke      the tool-chain smoke test (sjasmplus, bin2hex, Icarus)
#   make vsmoke     the same test built with Verilator
#   make hello      the system: the boot ROM prints "hello" over USB serial,
#                   twice (the second time after the RESET control command)
#   make systest    the system test ROM: system registers, I/O decode, SRAM
#                   bytes, writable boot ROM, soft reset
#   make speeds     the speed test ROM: "hello" at every CPUSPEED setting,
#                   with the T-state rates measured
#   make lint       Verilator lint of the RTL (fpga/lint.sh)
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

.PHONY: all smoke vsmoke hello systest speeds lint clean
all: smoke vsmoke hello systest speeds

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

$(BUILD)/boot.bin: $(ROOT)/firmware/boot/boot.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

$(BUILD)/systest.bin: systest/systest.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

$(BUILD)/speeds.bin: speeds/speeds.asm $(INC)/hw.inc | $(BUILD)
	$(SJASMPLUS) --nologo -I $(INC) --raw=$@ $<

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) $(ROOT)/tools/bin2hex.py $< $@

$(BUILD)/tb.vvp: $(TV80_CORE) $(SYS_RTL) $(SYS_SIM) $(RTL)/regmap.vh | $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -DTV80_REFRESH -I $(RTL) -s tb -o $@ 	    $(TV80_CORE) $(SYS_RTL) $(SYS_SIM)

hello: $(BUILD)/tb.vvp $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=boot.hex +hello +dma | tee hello.log
	@grep -q "^TEST PASSED" $(BUILD)/hello.log

systest: $(BUILD)/tb.vvp $(BUILD)/systest.hex $(BUILD)/boot.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=systest.hex +dma | tee systest.log
	@grep -q "^TEST PASSED" $(BUILD)/systest.log

speeds: $(BUILD)/tb.vvp $(BUILD)/speeds.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +rom=speeds.hex +speeds +dma +timeout=10000 | tee speeds.log
	@grep -q "^TEST PASSED" $(BUILD)/speeds.log

lint:
	sh $(ROOT)/fpga/lint.sh

clean:
	rm -rf $(BUILD)
