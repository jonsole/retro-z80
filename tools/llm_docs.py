#!/usr/bin/env python3
"""Register tables for docs/llm/, the reference written for AI models that
write Z80 programs for retro-z80.

The tables come from fpga/regmap.def (through tools/regmap.py's parser), so
they match firmware/include/hw.inc exactly. Each docs/llm/*.md file marks
where a table goes:

    <!-- gen:TABLE -->
    ... replaced by the generated table ...
    <!-- /gen:TABLE -->

TABLE is one of the names in TABLES below (python3 tools/llm_docs.py --list).

Usage:
  python3 tools/llm_docs.py            rewrite every generated table in docs/llm/*.md
  python3 tools/llm_docs.py --check    fail if a table is out of date, a name in a
                                       table is missing from hw.inc, or an asm block
                                       does not assemble
  python3 tools/llm_docs.py --asm      assemble every ```asm block in docs/llm/*.md
  python3 tools/llm_docs.py --list     the table names
  python3 tools/llm_docs.py --show T   print table T
  python3 tools/llm_docs.py ... FILE   any of the above for only these docs/llm files
                                       (name or stem, e.g. copper or copper.md)

An ```asm block is assembled on its own with sjasmplus (SJASMPLUS, or on the
PATH, or C:/tools/sjasmplus) and -I firmware/include. A block without its own
`include "hw.inc"` gets `device zxspectrum48`, `org 0x8000` and the include put
in front. Blocks that are not meant to assemble use ```text.
Uses only the Python standard library.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import regmap  # noqa: E402

DOCS = ROOT / "docs" / "llm"
HW_INC = ROOT / "firmware" / "include" / "hw.inc"
INC_DIR = ROOT / "firmware" / "include"

MARK = re.compile(r"(<!-- gen:([A-Za-z0-9_-]+) -->\n)(.*?)(<!-- /gen:\2 -->)", re.S)


# ---------------------------------------------------------------- the register map

def load():
    return regmap.parse((ROOT / "fpga" / "regmap.def").read_text(encoding="utf-8"))


def hw_names():
    names = set()
    for line in HW_INC.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)\s+equ\s", line)
        if m:
            names.add(m.group(1))
    return names


def hx(v, digits=2):
    return f"`0x{v:0{digits}X}`"


def access(acc, flags):
    return ",".join([acc] + sorted(flags))


def bits(f):
    return f"{f.hi}–{f.lo}" if f.hi != f.lo else f"{f.lo}"


def field_text(fields, width):
    """Fields, top bit first, in whole-value bit numbers; byte k holds bits 8k+7..8k."""
    if not fields:
        return "–" if width == 1 else "whole value"
    out = []
    for f in sorted(fields, key=lambda f: -f.hi):
        t = f"{f.name} {bits(f)}"
        if width > 1:
            lo_b, hi_b = f.lo // 8, f.hi // 8
            if lo_b == hi_b:
                hb, lb = f.hi - 8 * lo_b, f.lo - 8 * lo_b
                t += f" (b{lo_b}:{hb}–{lb})" if hb != lb else f" (b{lo_b}:{lb})"
            else:
                t += f" (b{lo_b}–b{hi_b})"
        out.append(t)
    return ", ".join(out)


class Row:
    def __init__(self, block, offset, name, width, acc, flags, spec, fields, rel=None):
        self.block, self.offset, self.name, self.width = block, offset, name, width
        self.acc, self.flags, self.spec, self.fields, self.rel = acc, flags, spec, fields, rel

    def port(self):
        return self.block.port(self.offset) if self.block.io else None


def rows(rm, block, lo, hi):
    """Plain registers and register lists of a block with lo <= offset <= hi, in offset order."""
    b = rm.block(block)
    out = []
    for r in b.regs:
        if lo <= r.offset <= hi:
            out.append(Row(b, r.offset, r.name, r.width, r.access, r.flags, r.spec, r.fields))
    for rl in b.reglists:
        for i in range(rl.count):
            off = rl.offset + i * rl.width
            if lo <= off <= hi:
                out.append(Row(b, off, regmap.byte_name(rl.name, i), rl.width, rl.access, rl.flags,
                               rl.spec, rl.fields))
    return sorted(out, key=lambda r: r.offset)


def name_cell(r, names):
    """The name, then the names of its bytes where it is wider than one."""
    t = f"`{r.name}`"
    if r.width > 1:
        bn = [regmap.byte_name(r.name, i) for i in range(r.width)]
        for n in bn:
            names.append(n)
        t += f" ({'/'.join(bn)})" if len(bn) <= 4 else ""
    names.append(r.name)
    return t


def reg_table(rm, block, ranges, names):
    hdr = ("| Offset | Port (`_P`) | Name (bytes) | Bytes | Access | Fields, whole-value bits (bK: bits in byte K) |\n"
           "|--------|-------------|--------------|-------|--------|------------------------------------------------|")
    if not rm.block(block).io:
        hdr = hdr.replace("| Port (`_P`) ", "").replace("|-------------", "")
    lines = [hdr]
    b = rm.block(block)
    for lo, hi in ranges:
        for r in rows(rm, block, lo, hi):
            port = f" {hx(r.port(), 4)} |" if b.io else ""
            lines.append(f"| {hx(r.offset, 3 if b.page >= 0x10 else 2)} |{port} {name_cell(r, names)} | {r.width} | "
                         f"{access(r.acc, r.flags)} | {field_text(r.fields, r.width)} |")
            if b.io:
                names.append(r.name + "_P")
    return "\n".join(lines)


def group_table(rm, block, gname, names):
    b = rm.block(block)
    g = next(g for g in b.groups if g.name == gname)
    gen = g.generic
    digits = 3 if b.page >= 0x10 else 2
    elems = []
    for n in range(g.count):
        base = g.base + n * g.stride
        e = g.elem(n)
        elems.append(f"{e} {hx(base, digits)}" + (f"/{hx(b.port(base), 4)}" if b.io else ""))
    out = [f"{g.count} elements, {hx(g.stride)} bytes apart: element n at {hx(g.base, digits)} + n × {hx(g.stride)}. "
           f"Bases (offset/port): " + ", ".join(elems) + ".",
           ""]
    whole = len(g.regs) == 1 and g.regs[0].name == "-"
    if whole:
        r = g.regs[0]
        out.append(f"Each element: {r.width} bytes, {access(r.access, r.flags)}; {field_text(r.fields, r.width)}. "
                   f"Bytes `{regmap.byte_name(g.elem(0), 0)}`…`{regmap.byte_name(g.elem(0), r.width - 1)}`.")
        for n in range(g.count):
            names.append(g.elem(n))
            names.append(g.elem(n) + "_P") if b.io else None
        return "\n".join(out)
    hdr = ("| +Off | Name (element 0; bytes) | Port, element 0 | Bytes | Access | Fields, whole-value bits (bK: bits in byte K) |\n"
           "|------|-------------------------|-----------------|-------|--------|------------------------------------------------|")
    if not b.io:
        hdr = hdr.replace("| Port, element 0 ", "").replace("|-----------------", "")
    out.append(hdr)
    for r in g.regs:
        e0 = f"{g.elem(0)}_{r.name}"
        row = Row(b, g.base + r.offset, e0, r.width, r.access, r.flags, r.spec, r.fields)
        port = f" {hx(b.port(g.base + r.offset), 4)} |" if b.io else ""
        out.append(f"| {hx(r.offset)} | {name_cell(row, names)} |{port} {r.width} | {access(r.access, r.flags)} | "
                   f"{field_text(r.fields, r.width)} |")
        names.append(f"{gen}_{r.name}")
        for n in range(g.count):
            names.append(f"{g.elem(n)}_{r.name}")
            if b.io:
                names.append(f"{g.elem(n)}_{r.name}_P")
    out.append("")
    out.append(f"Names: `{g.elem(0)}_X` … `{g.elem(g.count - 1)}_X` (offset), `_P` (port); `{gen}_X` is the offset "
               f"inside an element (add to `{gen}n`).")
    return "\n".join(out)


def desc_table(rm, first, last, names, title):
    """A descriptor laid out as the job registers first..last: one row per 4-byte word."""
    b = rm.block("CUSTOM")
    regs = [r for r in b.regs if first <= r.offset <= last]
    lines = [f"{title}\n",
             "| Byte | Word | Register | Byte 3 (bits 31–24) | Byte 2 (23–16) | Byte 1 (15–8) | Byte 0 (7–0) |",
             "|------|------|----------|---------------------|----------------|---------------|--------------|"]
    for r in regs:
        cells = []
        for k in (3, 2, 1, 0):
            if k >= r.width:
                cells.append("0 (no register byte)")
                continue
            parts = []
            for f in sorted(r.fields, key=lambda f: -f.hi):
                hi, lo = min(f.hi, 8 * k + 7), max(f.lo, 8 * k)
                if hi < lo:
                    continue
                if f.hi == hi and f.lo == lo:
                    parts.append(f"{f.name}" + (f" {hi - 8 * k}–{lo - 8 * k}" if hi != lo else f" {lo - 8 * k}"))
                else:
                    parts.append(f"{f.name}[{hi}:{lo}]")
            cells.append(", ".join(parts) if parts else "0")
        lines.append(f"| +{r.offset - first} | {(r.offset - first) // 4} | `{r.name}` | " + " | ".join(cells) + " |")
        names.append(r.name)
    lines.append("")
    lines.append("`NAME h–l`: the field in bits h–l of that byte. `NAME[h:l]`: bits h–l of a field wider than the "
                 "byte (whole-word numbering). Bits not named are reserved: write 0.")
    return "\n".join(lines)


def const_table(rm, names, prefix="", only=None):
    """Named numbers whose name starts with prefix (or is in only)."""
    lines = ["| Name | Value | Meaning |", "|------|-------|---------|"]
    for c in rm.consts:
        if (only is not None and c.name in only) or (only is None and c.name.startswith(prefix)):
            lines.append(f"| `{c.name}` | {hx(c.value) if c.value > 9 else c.value} | {c.text or ''} |")
            names.append(c.name)
    return "\n".join(lines)


def int_sources(rm, names):
    lines = ["| # | Name (`INT_`) | Byte (`INTR_`) | Bit (`INTB_`) | IM 2 vector |",
             "|---|---------------|----------------|---------------|-------------|"]
    for c in rm.consts:
        if c.name.startswith("INT_"):
            src = c.name[4:]
            if c.value < regmap.INT_SOURCES:
                lines.append(f"| {c.value} | `{src}` | INTENA{c.value // 7} / INTPEND{c.value // 7} | {c.value % 7} | "
                             f"VECBASE + {2 * c.value} |")
                names += [c.name, f"INTB_{src}", f"INTR_{src}"]
            else:
                lines.append(f"| {c.value} | `{src}` | – | – | VECBASE + {2 * c.value} ({c.text}) |")
                names.append(c.name)
    return "\n".join(lines)


def areas(rm, names):
    b = rm.block("REGS")
    lines = ["| Offset in register page | Size | Access | Name (`REGS_`) |", "|------|------|--------|------|"]
    for a in b.areas:
        lines.append(f"| {hx(a.offset, 4)} | {hx(a.size, 3)} | {a.access} | `REGS_{a.name}` |")
        names.append(f"REGS_{a.name}")
    return "\n".join(lines)


def ports(rm, names):
    lines = ["| Port (any high byte) | Register in page `0x00` | Name (`_PORT`) |", "|------|------|------|"]
    for p in rm.ports:
        lines.append(f"| {hx(p.lowbyte)} | {hx(p.register)} | `{p.name}_PORT` |")
        names.append(f"{p.name}_PORT")
    return "\n".join(lines)


# Each table: a function of (rm, names) -> Markdown text.
def R(block, *ranges):
    return lambda rm, n: reg_table(rm, block, ranges, n)


def G(block, gname):
    return lambda rm, n: group_table(rm, block, gname, n)


TABLES = {
    # system.md
    "system-regs": R("SYSTEM", (0x70, 0x7F)),
    "mmu": G("SYSTEM", "MMU"),
    "mmuw": G("SYSTEM", "MMUnW"),
    "lowports": ports,
    "regpage": areas,
    "int-sources": int_sources,
    "consts-sys": lambda rm, n: const_table(rm, n, only=(
        "SYSPAGE", "IPPAGE", "DBGPAGE", "CUSTPAGE", "REGS_IPPAGE", "REGS_DBGPAGE", "REGS_PALETTE", "REGS_PAL_SPAN",
        "SYSRESET_MAGIC", "WDKICK_MAGIC")),
    # video-layers.md
    "video-globals": R("CUSTOM", (0x000, 0x00F)),
    "layers": G("CUSTOM", "L"),
    "video-ro": R("CUSTOM", (0x0F0, 0x0FF)),
    "attr": R("CUSTOM", (0x130, 0x13F)),
    "video-consts": lambda rm, n: const_table(rm, n, only=("VID_X0", "VID_Y0", "VID_W", "VID_H", "BEAM_W", "BEAM_H")),
    "map-entry": lambda rm, n: const_table(rm, n, "ME_"),
    # sprites.md
    "sprites": G("CUSTOM", "SPR"),
    "sprite-globals": R("CUSTOM", (0x120, 0x12F)),
    "sequencer": R("CUSTOM", (0x300, 0x30F)),
    "seq-consts": lambda rm, n: const_table(rm, n, "SEQ_"),
    # copper.md
    "copper": R("CUSTOM", (0x100, 0x11F)),
    # blitter.md
    "blitter": R("CUSTOM", (0x140, 0x17F)),
    "blitter-desc": lambda rm, n: desc_table(rm, 0x140, 0x15C, n,
                                             "Descriptor (32 bytes, little-endian words; the same layout as `BLTCTRL`…`BLTNEXT`):"),
    "dmxint": R("CUSTOM", (0x230, 0x23F)),
    # rasteriser.md
    "raster": R("CUSTOM", (0x180, 0x1B3)),
    "raster-desc": lambda rm, n: desc_table(rm, 0x180, 0x19C, n,
                                            "Descriptor (32 bytes, little-endian words; the same layout as `RASCTRL`…`RASNEXT`):"),
    # sound.md
    "audio": R("CUSTOM", (0x240, 0x27F)),
    "audio-ch": G("CUSTOM", "AUD"),
    # interrupts-timers.md
    "intc": R("SYSTEM", (0x00, 0x0F)),
    "timers": G("SYSTEM", "TMR"),
    "time-wd": R("SYSTEM", (0x20, 0x27), (0x48, 0x4F)),
    "intpages": R("INTPAGES", (0x40, 0x4F)),
    "intpages-ip": lambda rm, n: "\n\n".join(group_table(rm, "INTPAGES", g, n) for g in
                                             ("IP", "IPnW", "IPSAV", "IPSAVnW", "NMIP", "NMIPnW", "NMISAV", "NMISAVnW")),
    # input.md
    "input-sys": R("SYSTEM", (0x10, 0x1F), (0x60, 0x6F), (0xFE, 0xFE)),
    "keyrow": R("REGS", (0x100, 0x107)),
    # serial-debug.md
    "serial": R("SYSTEM", (0x50, 0x57), (0x5C, 0x5C)),
    "sd": R("SYSTEM", (0x58, 0x5B), (0x5D, 0x5F)),
    "debug": R("DEBUG", (0x00, 0x0F)),
    "debug-bp": G("DEBUG", "DBGBP"),
    "debug-wp": G("DEBUG", "DBGWP"),
    # geometry.md
    "geometry": R("SYSTEM", (0xA0, 0xBF)),
    "geo-consts": lambda rm, n: const_table(rm, n, "GEO_"),
}


def render(name, rm):
    names = []
    text = TABLES[name](rm, names)
    note = f"<!-- Generated by tools/llm_docs.py from fpga/regmap.def; do not edit by hand. -->\n"
    return note + text + "\n", names


# ---------------------------------------------------------------- the files

def doc_files(only):
    files = sorted(DOCS.glob("*.md"))
    if only:
        files = [f for f in files if f.name in only or f.stem in only]
    return files


def update(check, only=None):
    rm = load()
    known = hw_names()
    bad = []
    for path in doc_files(only):
        text = path.read_text(encoding="utf-8")

        def sub(m):
            name = m.group(2)
            if name not in TABLES:
                bad.append(f"{path.name}: unknown table '{name}'")
                return m.group(0)
            body, names = render(name, rm)
            for n in names:
                if n not in known:
                    bad.append(f"{path.name}: table {name}: {n} is not in hw.inc")
            return m.group(1) + body + m.group(4)

        new = MARK.sub(sub, text)
        if new != text:
            if check:
                bad.append(f"{path.name}: generated tables are out of date (run python3 tools/llm_docs.py)")
            else:
                path.write_text(new, encoding="utf-8", newline="\n")
                print(f"llm_docs: wrote {path.relative_to(ROOT)}")
    return bad


# ---------------------------------------------------------------- the asm blocks

ASM_BLOCK = re.compile(r"^```asm\n(.*?)^```", re.S | re.M)
PRELUDE = '        device  zxspectrum48\n        org     0x8000\n        include "hw.inc"\n'


def sjasmplus():
    exe = os.environ.get("SJASMPLUS") or shutil.which("sjasmplus")
    if not exe:
        for p in ("C:/tools/sjasmplus/sjasmplus.exe", "/c/tools/sjasmplus/sjasmplus.exe"):
            if os.path.exists(p):
                exe = p
                break
    return exe


def assemble_all(only=None):
    exe = sjasmplus()
    if not exe:
        return ["sjasmplus not found: set SJASMPLUS or put it on the PATH"]
    bad = []
    count = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path in doc_files(only):
            text = path.read_text(encoding="utf-8")
            for i, m in enumerate(ASM_BLOCK.finditer(text)):
                src = m.group(1)
                if 'include "hw.inc"' not in src:
                    src = PRELUDE + src
                line = text[:m.start()].count("\n") + 1
                asm = Path(tmp) / f"{path.stem}_{i}.asm"
                asm.write_text(src, encoding="utf-8")
                # forward slashes: sjasmplus warns about a \ in a file name
                r = subprocess.run([exe, "--nologo", f"-I{Path(INC_DIR).as_posix()}",
                                    f"--raw={asm.with_suffix('.bin').as_posix()}", asm.as_posix()],
                                   capture_output=True, text=True, cwd=tmp)
                count += 1
                out = (r.stdout + r.stderr)
                if r.returncode != 0 or not re.search(r"Errors: 0, warnings: 0", out):
                    msg = "\n    ".join(l for l in out.splitlines() if "rror" in l or "arning" in l)
                    bad.append(f"{path.name}:{line}: asm block does not assemble:\n    {msg}")
    print(f"llm_docs: {count} asm blocks assembled, {len(bad)} failed")
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--asm", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--show")
    ap.add_argument("files", nargs="*", help="only these docs/llm files (name or stem); default all")
    a = ap.parse_args(argv)
    if a.list:
        print("\n".join(TABLES))
        return 0
    if a.show:
        print(render(a.show, load())[0])
        return 0
    if a.asm:
        bad = assemble_all(a.files)
    else:
        bad = update(a.check, a.files)
        if a.check:
            bad += assemble_all(a.files)
    for b in bad:
        print("llm_docs: " + b, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
