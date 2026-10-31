#!/usr/bin/env bash
# retro-z80: build the computer for the KS2 (issue #11), or the test pattern
# (issue #10), and load it over JTAG.
#
#   fpga/ks2/build.sh                 build fpga/ks2/build/retroz80_ks2.bit
#   fpga/ks2/build.sh --program       build, then load it over JTAG with Vivado
#   fpga/ks2/build.sh --program-only  just load the last build
#   fpga/ks2/build.sh --geom ...      the geometry unit in place of the DMA engine
#                                     (fpga/ks2/build/geom/retroz80_ks2.bit; spec 15)
#   fpga/ks2/build.sh --no-copper ... no copper, for room (build/nocopper/; with
#                                     --geom, build/geom-nocopper/)
#   fpga/ks2/build.sh --pattern ...   the same for the test pattern
#                                     (fpga/ks2/build/pattern/ks2_pattern.bit)
#
# Needs Vivado 2026.1 (the free edition covers the XC7A15T) on the PATH or
# in $VIVADO; for the computer also sjasmplus (PATH or $SJASMPLUS) and
# Python 3 (PATH or $PYTHON), for the boot ROM. On Windows, from Git Bash or
# MSYS2:
#   VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks2/build.sh
#
# Loading over JTAG changes nothing in the board's flash: power-cycle the KS2
# and it starts the Next as usual.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
what=machine
do_build=1
do_program=0
geom=0
copper=1

while [ $# -gt 0 ]; do
    case "$1" in
        --pattern)      what=pattern ;;
        --geom)         geom=1 ;;
        --no-copper)    copper=0 ;;
        --program)      do_program=1 ;;
        --program-only) do_program=1; do_build=0 ;;
        -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
        *)              echo "build.sh: unknown option $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [ "$what" = pattern ]; then
    out="$here/build/pattern"
    bit="$out/ks2_pattern.bit"
else
    out="$here/build"
    [ "$geom" = 1 ] && out="$here/build/geom"
    [ "$copper" = 0 ] && out="$here/build/nocopper"
    [ "$geom" = 1 ] && [ "$copper" = 0 ] && out="$here/build/geom-nocopper"
    bit="$out/retroz80_ks2.bit"
fi

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

vivado="${VIVADO:-$(command -v vivado || true)}"
[ -n "$vivado" ] || die "Vivado not found: put it on the PATH or set VIVADO"

if [ "$do_build" = 1 ]; then
    mkdir -p "$out"
    if [ "$what" = machine ]; then
        sjasmplus="${SJASMPLUS:-$(command -v sjasmplus || true)}"
        if [ -z "$sjasmplus" ] && [ -x /c/tools/sjasmplus/sjasmplus.exe ]; then
            sjasmplus=/c/tools/sjasmplus/sjasmplus.exe     # where the main README puts it
        fi
        [ -n "$sjasmplus" ] || die "sjasmplus not found: put it on the PATH or set SJASMPLUS"
        python="${PYTHON:-$(command -v python3 || command -v python || true)}"
        [ -n "$python" ] || die "Python not found: put it on the PATH or set PYTHON"
        say "Assembling the boot ROM"
        "$sjasmplus" --nologo -I "$root/firmware/include" --raw="$out/boot.bin" "$root/firmware/boot/boot.asm"
        "$python" "$root/tools/bin2hex.py" "$out/boot.bin" "$out/boot.hex"
    fi
    say "Running Vivado (synthesis, place and route, bitstream): a few minutes"
    set +e
    (cd "$out" && "$vivado" -mode batch -nojournal -log vivado.log \
        -source "$here/build.tcl" -tclargs "$root" "$out" "$what" "$geom" "$copper")
    status=$?
    set -e
    grep -h "^retro-z80:" "$out/vivado.log" || true
    case $status in
        0) ;;
        2) die "timing not met: see $out/timing.txt (the bitstream was written anyway)" ;;
        *) die "Vivado failed: see $out/vivado.log" ;;
    esac
    say "Done: $bit"
    echo "    reports: utilization.txt, utilization_hier.txt, timing.txt, clocks.txt, drc.txt, io.txt"
fi

if [ "$do_program" = 1 ]; then
    [ -f "$bit" ] || die "no bitstream yet: run build.sh first"
    say "Loading over JTAG with Vivado"
    (cd "$out" && "$vivado" -mode batch -nojournal -log program.log \
        -source "$here/program.tcl" -tclargs "$bit")
fi
