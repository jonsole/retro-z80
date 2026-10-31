#!/bin/sh
# Assembles the geometry examples (docs/guide/geometry.md) into build/, each
# as a raw binary, its SLD, and an image for the upload: sh build.sh [name...]
cd "$(dirname "$0")"
SJ=${SJASMPLUS:-/c/tools/sjasmplus/sjasmplus.exe}
mkdir -p build
[ -f sine.inc ] || python tables.py
for n in ${*:-first cube ring faces calc}; do
    "$SJ" --nologo --fullpath -I ../../firmware/include --raw=build/$n.bin --sld=build/$n.sld $n.asm || exit 1
    python ../../tools/rlink.py image --machine z80 --load 0x8000 --entry 0x8000 -o build/$n.rimg build/$n.bin
done
