#!/bin/sh
# Lint the RTL with Verilator, as retro68k does (fpga/rtl/README.md). A value
# cut short to fit where it goes (WIDTHTRUNC) is an error: it is how a
# register rebuilt from the wrong number of bits slips past Icarus. Widening
# (WIDTHEXPAND) is allowed. Where cutting is meant, slice it or waive that line:
#   /* verilator lint_off WIDTHTRUNC */ ... /* verilator lint_on WIDTHTRUNC */
# Style warnings (unused signals, empty pins) are left out; other warnings
# are shown but do not fail. The third-party CPU core is not checked
# (fpga/lint.vlt).
set -e
cd "$(dirname "$0")/.."
VERILATOR=${VERILATOR:-verilator}
$VERILATOR --lint-only --default-language 1364-2005 -Wall -Wno-style -Wno-fatal -Werror-WIDTHTRUNC \
    -DTV80_REFRESH -Ifpga/rtl --top-module retroz80 fpga/lint.vlt \
    fpga/third_party/tv80/tv80_core.v fpga/third_party/tv80/tv80_alu.v \
    fpga/third_party/tv80/tv80_mcode.v fpga/third_party/tv80/tv80_reg.v \
    fpga/rtl/*.v
echo "lint: no widths cut short"
