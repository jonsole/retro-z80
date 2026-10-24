#!/bin/sh
# Lint the RTL with Verilator, as retro68k does (fpga/rtl/README.md). A value
# cut short to fit where it goes (WIDTHTRUNC) is an error: it is how a
# register rebuilt from the wrong number of bits slips past Icarus. Widening
# (WIDTHEXPAND) is allowed. Where cutting is meant, slice it or waive that line:
#   /* verilator lint_off WIDTHTRUNC */ ... /* verilator lint_on WIDTHTRUNC */
# Style warnings (unused signals, empty pins) are left out; other warnings
# are shown but do not fail. The third-party CPU core is not checked
# (fpga/lint.vlt). The KS2 test pattern build is linted on its own, with
# stand-ins for the Xilinx primitives (fpga/lint_xilinx_stub.v).
set -e
cd "$(dirname "$0")/.."
VERILATOR=${VERILATOR:-verilator}
$VERILATOR --lint-only --default-language 1364-2005 -Wall -Wno-style -Wno-fatal -Werror-WIDTHTRUNC \
    -DTV80_REFRESH -Ifpga/rtl --top-module retroz80 fpga/lint.vlt \
    fpga/third_party/tv80/tv80_core.v fpga/third_party/tv80/tv80_alu.v \
    fpga/third_party/tv80/tv80_mcode.v fpga/third_party/tv80/tv80_reg.v \
    fpga/rtl/*.v
$VERILATOR --lint-only --default-language 1364-2005 -Wall -Wno-style -Wno-fatal -Werror-WIDTHTRUNC     --top-module top_ks2_pattern fpga/ks2/top_ks2_pattern.v fpga/rtl/tmds_encoder.v     fpga/rtl/platform/artix7/ks2_clocks.v fpga/rtl/platform/artix7/hdmi_out.v fpga/lint_xilinx_stub.v
echo "lint: no widths cut short"
