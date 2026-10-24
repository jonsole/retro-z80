#!/usr/bin/env bash
# retro-z80: build the KS2 test pattern (issue #10) and load it over JTAG.
#
#   fpga/ks2/build.sh                 build fpga/ks2/build/ks2_pattern.bit
#   fpga/ks2/build.sh --program       build, then load it over JTAG with Vivado
#   fpga/ks2/build.sh --program-only  just load the last build
#
# Needs Vivado 2026.1 (the free edition covers the XC7A15T) on the PATH or
# in $VIVADO. On Windows, from Git Bash or MSYS2:
#   VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks2/build.sh
#
# Loading over JTAG changes nothing in the board's flash: power-cycle the KS2
# and it starts the Next as usual.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/build"
bit="$out/ks2_pattern.bit"
do_build=1
do_program=0

while [ $# -gt 0 ]; do
    case "$1" in
        --program)      do_program=1 ;;
        --program-only) do_program=1; do_build=0 ;;
        -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
        *)              echo "build.sh: unknown option $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

vivado="${VIVADO:-$(command -v vivado || true)}"
[ -n "$vivado" ] || die "Vivado not found: put it on the PATH or set VIVADO"

if [ "$do_build" = 1 ]; then
    mkdir -p "$out"
    say "Running Vivado (synthesis, place and route, bitstream): a few minutes"
    set +e
    (cd "$out" && "$vivado" -mode batch -nojournal -log vivado.log \
        -source "$here/build.tcl" -tclargs "$root" "$out")
    status=$?
    set -e
    grep -h "^retro-z80:" "$out/vivado.log" || true
    case $status in
        0) ;;
        2) die "timing not met: see $out/timing.txt (the bitstream was written anyway)" ;;
        *) die "Vivado failed: see $out/vivado.log" ;;
    esac
    say "Done: $bit"
    echo "    reports: utilization.txt, timing.txt, clocks.txt, drc.txt, io.txt"
fi

if [ "$do_program" = 1 ]; then
    [ -f "$bit" ] || die "no bitstream yet: run build.sh first"
    say "Loading over JTAG with Vivado"
    (cd "$out" && "$vivado" -mode batch -nojournal -log program.log \
        -source "$here/program.tcl" -tclargs "$bit")
fi
