#!/usr/bin/env python3
"""retro-z80 register map generator.

Reads fpga/regmap.def (the one source for every register, spec 3 section 8) and:
  * checks it for mistakes (overlaps, widths, bad fields, duplicate names, copper reach),
  * checks it against the tables in docs/spec/registers.md, and the named values
    the specs quote (`NAME` = `0x..`),
  * writes firmware/include/hw.inc (sjasmplus), firmware/include/hw.h (C, z88dk)
    and fpga/rtl/regmap.vh (Verilog).

Usage:
  python3 tools/regmap.py            check, then write the generated files
  python3 tools/regmap.py --verify   check, and fail if a generated file is out of date (for CI)

--def, --spec and --out point it at other files (the self-test uses them).
Uses only the Python standard library.
"""

import argparse
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEF_FILE = ROOT / "fpga" / "regmap.def"
SPEC_FILE = ROOT / "docs" / "spec" / "registers.md"
OUT_ASM = Path("firmware") / "include" / "hw.inc"
OUT_C = Path("firmware") / "include" / "hw.h"
OUT_V = Path("fpga") / "rtl" / "regmap.vh"

ACCESS = {"R", "W", "RW", "W1C", "RW1C", "SC", "S"}
FLAGS = {"CAP", "SEP", "COLR", "MMU", "PAIR", "F", "LOCK", "BUSY"}
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")

# Spec 3, section 5.1: what a copper list changes per line must be within MOVE's reach.
MOVE_TOP = 0x0EF
MOVE_ARRAYS = ("SPR", "L")
MOVE_REGS = ("VIDCON", "VIDSTAT", "VIDINTEN", "PRIO", "BGCOLOR", "LINECMP", "PALIDX", "PALDAT", "DMACON")
INT_SOURCES = 21  # sources 0-20 have enable bits, 7 to a byte (spec 8)


class DefError(Exception):
    pass


@dataclass
class Field:
    name: str
    hi: int
    lo: int

    @property
    def width(self):
        return self.hi - self.lo + 1

    @property
    def mask(self):
        return ((1 << self.width) - 1) << self.lo


@dataclass
class Reg:
    offset: int
    name: str
    width: int
    access: str
    flags: frozenset
    spec: str
    fields: list = field(default_factory=list)
    copy_from: str = None
    line: int = 0


@dataclass
class RegList:
    name: str
    count: int
    offset: int
    width: int
    access: str
    flags: frozenset
    spec: str
    fields: list = field(default_factory=list)
    line: int = 0


@dataclass
class Group:
    name: str  # a lower-case n marks where the index goes (MMUnW)
    count: int
    base: int
    stride: int
    spec: str
    regs: list = field(default_factory=list)
    line: int = 0

    @property
    def generic(self):
        return self.name.replace("n", "")

    def elem(self, n):
        return self.name.replace("n", str(n)) if "n" in self.name else f"{self.name}{n}"


@dataclass
class Area:
    name: str
    offset: int
    size: int
    access: str
    spec: str
    line: int = 0


@dataclass
class Block:
    name: str
    page: int
    size: int
    text: str
    regs: list = field(default_factory=list)
    reglists: list = field(default_factory=list)
    groups: list = field(default_factory=list)
    areas: list = field(default_factory=list)

    @property
    def io(self):
        return self.page < 0x100

    def port(self, k):
        return ((k & 0xFF) << 8) | (self.page + (k >> 8))

    def bus(self, k):
        """Register bus address = register page offset (spec 3, section 3.2)."""
        return self.page * 256 + k if self.io else k


@dataclass
class Port:
    name: str
    lowbyte: int
    register: int
    line: int = 0


@dataclass
class Const:
    name: str
    value: int
    text: str
    line: int = 0


@dataclass
class RegMap:
    blocks: list = field(default_factory=list)
    ports: list = field(default_factory=list)
    consts: list = field(default_factory=list)

    def block(self, name):
        return next((b for b in self.blocks if b.name == name), None)


def byte_name(name, i):
    """NAME0..NAME3; an underscore first where the name ends in a digit or an index and a letter."""
    return f"{name}_{i}" if re.search(r"\d[A-Z]?$", name) else f"{name}{i}"


# ---------------------------------------------------------------- parsing

def num(tok, line):
    try:
        return int(tok, 0)
    except ValueError:
        raise DefError(f"line {line}: '{tok}' is not a number")


def check_name(name, line):
    if not NAME_RE.match(name):
        raise DefError(f"line {line}: bad name '{name}' (use capitals, digits and _)")


def parse_access(tok, line):
    parts = tok.split(",")
    if parts[0] not in ACCESS:
        raise DefError(f"line {line}: unknown access '{parts[0]}'")
    for f in parts[1:]:
        if f not in FLAGS:
            raise DefError(f"line {line}: unknown access flag '{f}'")
    return parts[0], frozenset(parts[1:])


def parse_fields(tokens, line):
    fields, copy_from = [], None
    for tok in tokens:
        if tok.startswith("fields="):
            copy_from = tok.split("=", 1)[1]
            continue
        if "=" not in tok:
            raise DefError(f"line {line}: field '{tok}' must be NAME=BIT or NAME=HIGH:LOW")
        name, bits = tok.split("=", 1)
        check_name(name, line)
        if ":" in bits:
            hi, lo = (num(b, line) for b in bits.split(":", 1))
        else:
            hi = lo = num(bits, line)
        if not (0 <= lo <= hi <= 31):
            raise DefError(f"line {line}: field {name} bits {bits} must be within 31..0, high first")
        fields.append(Field(name, hi, lo))
    return fields, copy_from


def parse(text):
    rm = RegMap()
    block = None
    group = None
    for ln, raw in enumerate(text.splitlines(), 1):
        try:
            tok = shlex.split(raw, comments=True)
        except ValueError as e:
            raise DefError(f"line {ln}: {e}")
        if not tok:
            continue
        kw = tok[0]
        if group is not None and kw not in ("reg", "end"):
            raise DefError(f"line {ln}: only 'reg' and 'end' are allowed inside array {group.name}")
        if kw == "block":
            if len(tok) < 4:
                raise DefError(f"line {ln}: block needs NAME PAGE SIZE")
            check_name(tok[1], ln)
            block = Block(tok[1], num(tok[2], ln), num(tok[3], ln), tok[4] if len(tok) > 4 else "")
            rm.blocks.append(block)
        elif kw == "reg":
            if len(tok) < 6:
                raise DefError(f"line {ln}: reg needs OFFSET NAME WIDTH ACCESS SPEC")
            name = tok[2]
            if not (name == "-" and group is not None):
                check_name(name, ln)
            access, flags = parse_access(tok[4], ln)
            fields, copy_from = parse_fields(tok[6:], ln)
            r = Reg(num(tok[1], ln), name, num(tok[3], ln), access, flags, tok[5], fields, copy_from, ln)
            if group is not None:
                group.regs.append(r)
            elif block is None:
                raise DefError(f"line {ln}: reg outside a block")
            else:
                block.regs.append(r)
        elif kw == "regs":
            if block is None or len(tok) < 7:
                raise DefError(f"line {ln}: regs needs NAME COUNT OFFSET WIDTH ACCESS SPEC inside a block")
            check_name(tok[1], ln)
            access, flags = parse_access(tok[5], ln)
            fields, copy_from = parse_fields(tok[7:], ln)
            if copy_from:
                raise DefError(f"line {ln}: fields= is not supported on regs")
            block.reglists.append(RegList(tok[1], num(tok[2], ln), num(tok[3], ln), num(tok[4], ln),
                                          access, flags, tok[6], fields, ln))
        elif kw == "array":
            if block is None or len(tok) < 6:
                raise DefError(f"line {ln}: array needs NAME COUNT OFFSET STRIDE SPEC inside a block")
            check_name(tok[1].replace("n", "0"), ln)
            group = Group(tok[1], num(tok[2], ln), num(tok[3], ln), num(tok[4], ln), tok[5], line=ln)
            block.groups.append(group)
        elif kw == "end":
            if group is None:
                raise DefError(f"line {ln}: 'end' without array")
            group = None
        elif kw == "area":
            if block is None or len(tok) < 6:
                raise DefError(f"line {ln}: area needs NAME OFFSET SIZE ACCESS SPEC inside a block")
            check_name(tok[1], ln)
            block.areas.append(Area(tok[1], num(tok[2], ln), num(tok[3], ln), tok[4], tok[5], ln))
        elif kw == "port":
            if len(tok) != 4:
                raise DefError(f"line {ln}: port needs NAME LOWBYTE REGISTER")
            check_name(tok[1], ln)
            rm.ports.append(Port(tok[1], num(tok[2], ln), num(tok[3], ln), ln))
        elif kw == "const":
            if len(tok) < 3:
                raise DefError(f"line {ln}: const needs NAME VALUE")
            check_name(tok[1], ln)
            rm.consts.append(Const(tok[1], num(tok[2], ln), tok[3] if len(tok) > 3 else "", ln))
        else:
            raise DefError(f"line {ln}: unknown keyword '{kw}'")
    if group is not None:
        raise DefError(f"array {group.name} (line {group.line}) has no 'end'")
    for b in rm.blocks:
        by_name = {r.name: r for r in b.regs}
        for r in b.regs:
            if r.copy_from:
                src = by_name.get(r.copy_from)
                if src is None:
                    raise DefError(f"line {r.line}: fields={r.copy_from}: no such register in block {b.name}")
                r.fields = list(src.fields) + r.fields
    return rm


# ---------------------------------------------------------------- the registers, flattened

@dataclass
class Flat:
    """One register at its absolute offset in its block."""
    block: Block
    offset: int
    name: str          # full name, e.g. SPR0_PT, MMU0W, INTENA1
    width: int
    access: str
    flags: frozenset
    spec: str
    group: Group = None
    reg: Reg = None    # the group's register (for comparing with relative spec rows)


def flat_registers(rm):
    out = []
    for b in rm.blocks:
        for r in b.regs:
            out.append(Flat(b, r.offset, r.name, r.width, r.access, r.flags, r.spec, reg=r))
        for rl in b.reglists:
            for i in range(rl.count):
                out.append(Flat(b, rl.offset + i * rl.width, byte_name(rl.name, i), rl.width,
                                rl.access, rl.flags, rl.spec))
        for g in b.groups:
            for n in range(g.count):
                for r in g.regs:
                    name = g.elem(n) if r.name == "-" else f"{g.elem(n)}_{r.name}"
                    out.append(Flat(b, g.base + n * g.stride + r.offset, name, r.width,
                                    r.access, r.flags, r.spec, g, r))
    return out


# ---------------------------------------------------------------- checks

def check(rm):
    errors = []

    def check_fields(fields, width, where):
        used = 0
        for f in fields:
            if f.hi >= 8 * width:
                errors.append(f"{where}: field {f.name} (bits {f.hi}:{f.lo}) is outside the {width}-byte register")
            if used & f.mask:
                errors.append(f"{where}: field {f.name} overlaps another field")
            used |= f.mask
        names = [f.name for f in fields]
        if len(names) != len(set(names)):
            errors.append(f"{where}: duplicate field names")

    for b in rm.blocks:
        for r in b.regs:
            check_fields(r.fields, r.width, f"{b.name}.{r.name} (line {r.line})")
        for rl in b.reglists:
            check_fields(rl.fields, rl.width, f"{b.name}.{rl.name} (line {rl.line})")
        for g in b.groups:
            for r in g.regs:
                where = f"array {g.name}.{r.name} (line {r.line})"
                if r.offset < 0 or r.offset + r.width > g.stride:
                    errors.append(f"{where}: offset 0x{r.offset:X} is outside the {g.stride}-byte element")
                if r.copy_from:
                    errors.append(f"{where}: fields= is only supported outside arrays")
                if r.name == "-" and (r.offset != 0 or len(g.regs) != 1):
                    errors.append(f"{where}: '-' must be an element's only register, at offset 0")
                check_fields(r.fields, r.width, where)

    for f in flat_registers(rm):
        if not 1 <= f.width <= 4:
            errors.append(f"{f.block.name}.{f.name}: width {f.width} is not 1-4 bytes")

    # every byte inside its block, nothing overlapping
    for b in rm.blocks:
        owner = {}
        for f in (x for x in flat_registers(rm) if x.block is b):
            if f.offset < 0 or f.offset + f.width > b.size:
                errors.append(f"block {b.name}: {f.name} at 0x{f.offset:X} is outside the block")
            for a in range(f.offset, f.offset + f.width):
                if a in owner:
                    errors.append(f"block {b.name}: {f.name} at 0x{a:X} overlaps {owner[a]}")
                    break
                owner[a] = f.name
        area_owner = {}
        for a in b.areas:
            if a.offset < 0 or a.offset + a.size > b.size:
                errors.append(f"block {b.name}: area {a.name} is outside the block")
            for x in range(a.offset, a.offset + a.size):
                if x in area_owner:
                    errors.append(f"block {b.name}: area {a.name} at 0x{x:X} overlaps {area_owner[x]}")
                    break
                area_owner[x] = a.name

    # low-byte-only ports
    system = next((b for b in rm.blocks if b.io and b.page == 0x00), None)
    for p in rm.ports:
        where = f"port {p.name} (line {p.line})"
        if p.lowbyte != p.register:
            errors.append(f"{where}: low byte 0x{p.lowbyte:02X} must be its register number 0x{p.register:02X}")
        reg = None if system is None else next((r for r in system.regs if r.offset == p.register), None)
        if reg is None:
            errors.append(f"{where}: no register 0x{p.register:02X} in page 0x00")
        elif reg.name != p.name:
            errors.append(f"{where}: register 0x{p.register:02X} is {reg.name}, not {p.name}")
        elif reg.width != 1:
            errors.append(f"{where}: {reg.name} must be one byte")

    # copper MOVE reach
    for f in flat_registers(rm):
        if f.block.name != "CUSTOM":
            continue
        needs_move = (f.group is not None and f.group.name in MOVE_ARRAYS) or f.name in MOVE_REGS
        if needs_move and f.offset + f.width - 1 > MOVE_TOP:
            errors.append(f"CUSTOM.{f.name} at 0x{f.offset:03X} is beyond a copper MOVE's reach (0x{MOVE_TOP:03X})")

    # interrupt sources
    for c in rm.consts:
        if c.name.startswith("INT_") and c.name != "INT_NONE" and not 0 <= c.value < INT_SOURCES:
            errors.append(f"const {c.name} (line {c.line}): source {c.value} has no enable bit (0-{INT_SOURCES - 1})")
    return errors


# ---------------------------------------------------------------- reading the spec

def md_tables(md_text):
    """Yield (headings, header cells, rows, preceding text lines) for every table."""
    lines = md_text.splitlines()
    h2 = h3 = ""
    text = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("## "):
            h2, h3, text = line, "", []
        elif line.startswith("### "):
            h3, text = line, []
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[-| ]+\|$", lines[i + 1].strip()):
            header = cells(line)
            rows = []
            i += 2
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(cells(lines[i]))
                i += 1
            yield (h2, h3), header, rows, list(text)
            continue
        if line.strip() and not line.startswith("|"):
            text.append(line)
        i += 1


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def norm_access(s):
    flags = set()
    if "CAP" in s:
        flags.add("CAP")
    if "(F)" in s:
        flags.add("F")
    if "lockable" in s:
        flags.add("LOCK")
    if "BUSY" in s:
        flags.add("BUSY")
    if s.startswith("SC"):
        base = "SC"
    elif "W (S)" in s or re.match(r"^S\b", s):
        base = "S"
    elif "W1C" in s:
        base = "RW1C" if re.search(r"\bR\b", s.replace("W1C", "")) else "W1C"
    elif s.startswith("RW"):
        base = "RW"
    elif s.startswith("R"):
        base = "R"
    elif s.startswith("W"):
        base = "W"
    else:
        base = None
    return base, frozenset(flags)


HEX = r"`\+?(0x[0-9A-Fa-f]+|\d+)`"


@dataclass
class SpecReg:
    block: str
    offset: int
    name: str   # None: the spec gives no name (register 0xFE)
    width: int
    access: tuple
    where: str
    rel_name: bool = False  # name is a group register's name (CTRL, PT), not a full name


CHECKED = ("SYSTEM", "INTPAGES", "CUSTOM")  # the blocks spec 3's tables list


def spec_registers(md_text):
    """Every register row of spec 3's tables in sections 4 and 5, expanded to absolute offsets.
    Section 4's subsection on page `0x01` is the INTPAGES block; the rest of section 4 the system page."""
    rows_out = []  # [block, offset, name, width, access, where, rel, bases]
    for (h2, h3), header, rows, text in md_tables(md_text):
        if h2.startswith("## 4"):
            blk = "INTPAGES" if "page `0x01`" in h3 else "SYSTEM"
        elif h2.startswith("## 5"):
            blk = "CUSTOM"
        else:
            continue
        if not {"Name", "Width", "Access"} <= set(header):
            continue
        col = {h: i for i, h in enumerate(header)}
        group = None
        for t in text:
            m = re.search(r"n \(0–(\d+)\) at (?:register )?`0x([0-9A-Fa-f]+)` \+ n × `?(0x[0-9A-Fa-f]+|\d+)`?", t)
            if m:
                cnt, base, stride = int(m.group(1)) + 1, int(m.group(2), 16), int(m.group(3), 0)
                group = [base + e * stride for e in range(cnt)]
        heading = h3 or h2
        prev = None
        for row in rows:
            first, name_cell = row[0], row[col["Name"]]
            wcell, acell = row[col["Width"]], row[col["Access"]]
            if not wcell:
                continue  # a pointer to another table, or a reserved row
            width = int(wcell.split()[0])
            access = norm_access(acell)
            where = f"{heading}: {first}"
            name = re.split(r" \(|:", name_cell)[0].strip()
            if name == "–":
                name = None
            mmu = re.match(r"^`0x([0-9A-Fa-f]+)` \+ (\d+)n$", first)
            if mmu:  # MMU rows: `0x80` + 2n, n = 0-7
                cnt = int(re.search(r"n = 0–(\d+)", section_text(md_text, heading)).group(1)) + 1
                for n in range(cnt):
                    rows_out.append([blk, int(mmu.group(1), 16) + n * int(mmu.group(2)),
                                     name.replace("n", str(n)), width, access, where, False, [0]])
                prev = None
                continue
            offs = [int(x, 0) for x in re.findall(HEX, first)]
            if not offs:
                continue
            start, end = offs[0], offs[-1]
            rel = first.startswith("`+")
            bases = [0]
            if rel:
                if group is None:
                    raise ValueError(f"{where}: relative offsets without 'n (0–k) at ... + n × ...'")
                bases = group
                if name:
                    name = re.sub(r"^[A-Z]+(x|_)(?=[A-Z])", "", name)  # SPRxPT, TMR_CTRL
            rng = re.match(r"^([A-Z][A-Z0-9_]*?)(\d+)–[A-Z_]*?(\d+)$", name or "")
            if rng:
                names = [f"{rng.group(1)}{i}" for i in range(int(rng.group(2)), int(rng.group(3)) + 1)]
                for i, n in enumerate(names):
                    rows_out.append([blk, start + i * width, n, width, access, where, rel, bases])
                prev = None
                continue
            if "each" in wcell:
                raise ValueError(f"{where}: 'each' without a name range")
            if prev is not None and name and prev[2] == name and prev[1] + prev[3] == start:
                prev[3] += end - start + 1  # one value in two rows (WINX: XEND, then XSTART)
                continue
            prev = [blk, start, name, end - start + 1, access, where, rel, bases]
            rows_out.append(prev)
    return [SpecReg(b, base + off, n, w, acc, where, rel)
            for b, off, n, w, acc, where, rel, bases in rows_out for base in bases]


def section_text(md_text, heading):
    lines = md_text.splitlines()
    try:
        i = lines.index(heading)
    except ValueError:
        return ""
    out = []
    for line in lines[i + 1:]:
        if line.startswith("#"):
            break
        out.append(line)
    return "\n".join(out)


def check_spec(rm, md_text):
    errors = []
    try:
        spec = spec_registers(md_text)
    except (ValueError, AttributeError) as e:
        return [f"registers.md: cannot read a table: {e}"]

    ours = {}
    for f in flat_registers(rm):
        if f.block.name in CHECKED:
            ours[(f.block.name, f.offset)] = f
    theirs = {}
    for s in spec:
        theirs[(s.block, s.offset)] = s

    for key in sorted(set(theirs) - set(ours)):
        s = theirs[key]
        errors.append(f"registers.md lists {s.name or 'a register'} at {key[0]}+0x{key[1]:X} ({s.where}), "
                      f"but regmap.def does not")
    for key in sorted(set(ours) - set(theirs)):
        f = ours[key]
        errors.append(f"regmap.def has {f.name} at {key[0]}+0x{key[1]:X}, but registers.md does not list it")
    for key in sorted(set(ours) & set(theirs)):
        f, s = ours[key], theirs[key]
        want = f.reg.name if (s.rel_name and f.reg is not None and f.group is not None) else f.name
        if s.name is not None and s.name != want:
            errors.append(f"{key[0]}+0x{key[1]:X}: registers.md names it {s.name}, regmap.def {want}")
        if s.width != f.width:
            errors.append(f"{f.name}: registers.md gives {s.width} bytes, regmap.def {f.width}")
        base, flags = s.access
        if base != f.access or flags != (f.flags & {"CAP", "F", "LOCK", "BUSY"}):
            ours_acc = ",".join([f.access] + sorted(f.flags & {"CAP", "F", "LOCK", "BUSY"}))
            theirs_acc = ",".join([str(base)] + sorted(flags))
            errors.append(f"{f.name}: registers.md gives access {theirs_acc}, regmap.def {ours_acc}")

    errors += check_spec_ports(rm, md_text)
    errors += check_spec_regpage(rm, md_text)
    errors += check_spec_interrupts(rm, md_text)
    return errors


def check_spec_ports(rm, md_text):
    errors = []
    spec = {}
    for (h2, h3), header, rows, text in md_tables(md_text):
        if header[:2] == ["Low-byte-only port", "Name"]:
            for row in rows:
                lo = int(re.search(HEX, row[0]).group(1), 0)
                m = re.match(r"^([A-Z][A-Z0-9_]*):", row[1])
                spec[lo] = m.group(1) if m else None
    ours = {p.lowbyte: p.name for p in rm.ports}
    if not spec:
        return ["registers.md: no low-byte-only port table found"]
    for lo in sorted(set(spec) ^ set(ours)):
        side = "registers.md" if lo in spec else "regmap.def"
        errors.append(f"low-byte-only port 0x{lo:02X} is only in {side}")
    for lo in sorted(set(spec) & set(ours)):
        if spec[lo] is not None and spec[lo] != ours[lo]:
            errors.append(f"low-byte-only port 0x{lo:02X}: registers.md names it {spec[lo]}, regmap.def {ours[lo]}")
    return errors


def check_spec_regpage(rm, md_text):
    errors = []
    regs = rm.block("REGS")
    if regs is None:
        return ["regmap.def has no REGS block (the register page)"]
    ours = {}
    for a in regs.areas:
        ours[(a.offset, a.offset + a.size - 1)] = a.name
    for rl in regs.reglists:
        ours[(rl.offset, rl.offset + rl.count * rl.width - 1)] = rl.name
    for r in regs.regs:
        ours[(r.offset, r.offset + r.width - 1)] = r.name
    # an I/O block other than the system page and the custom block shows as the span of its registers
    for b in rm.blocks:
        if b.io and b.name not in ("SYSTEM", "CUSTOM"):
            addrs = [b.bus(f.offset + i) for f in flat_registers(rm) if f.block is b for i in range(f.width)]
            if addrs:
                ours[(min(addrs), max(addrs))] = b.name
    spec = {}
    for (h2, h3), header, rows, text in md_tables(md_text):
        if not (h2.startswith("## 6") and header[:3] == ["Offset", "I/O page", "Contents"]):
            continue
        for row in rows:
            offs = [int(x, 0) for x in re.findall(HEX, row[0])]
            contents = row[2]
            if contents.startswith("Reserved") or not offs:
                continue
            m = re.match(r"^([A-Z][A-Z0-9]*?)\d+–\d+", contents) or re.match(r"^([A-Z][A-Z0-9_]+)\b", contents)
            if m:
                name = m.group(1)
            elif "system page" in contents:
                name = "SYSTEM"
            elif "custom block" in contents:
                name = "CUSTOM"
            else:
                name = None
            spec[(offs[0], offs[-1])] = name
    if not spec:
        return ["registers.md: no register page table found in section 6"]
    for key in sorted(set(spec) ^ set(ours)):
        side = "registers.md" if key in spec else "regmap.def"
        errors.append(f"register page 0x{key[0]:04X}-0x{key[1]:04X} ({spec.get(key) or ours.get(key)}) is only in {side}")
    for key in sorted(set(spec) & set(ours)):
        if spec[key] is not None and spec[key] != ours[key]:
            errors.append(f"register page 0x{key[0]:04X}: registers.md names it {spec[key]}, regmap.def {ours[key]}")
    for name, blk in (("SYSTEM", "SYSTEM"), ("CUSTOM", "CUSTOM")):
        b = rm.block(blk)
        a = next((a for a in regs.areas if a.name == name), None)
        if b is not None and a is not None and (a.offset != b.page * 256 or a.size != b.size):
            errors.append(f"register page area {name} must be block {blk}: 0x{b.page * 256:04X}, 0x{b.size:X} bytes")
    return errors


def check_spec_interrupts(rm, md_text):
    spec = {}
    for (h2, h3), header, rows, text in md_tables(md_text):
        if not (h2.startswith("## 7") and header[:2] == ["#", "Name"]):
            continue
        for row in rows:
            nums = [int(x) for x in re.findall(r"\d+", row[0])]
            name = row[1]
            if name == "–":
                continue
            rng = re.match(r"^([A-Z]+?)(\d+)–[A-Z]*?(\d+)$", name)
            if rng:
                for i, n in enumerate(range(nums[0], nums[-1] + 1)):
                    spec[f"INT_{rng.group(1)}{int(rng.group(2)) + i}"] = n
            else:
                spec[f"INT_{name}"] = nums[0]
    if not spec:
        return ["registers.md: no interrupt source table found in section 7"]
    ours = {c.name: c.value for c in rm.consts if c.name.startswith("INT_")}
    errors = []
    for name in sorted(set(spec) ^ set(ours)):
        side = "registers.md" if name in spec else "regmap.def"
        errors.append(f"interrupt source {name} is only in {side}")
    for name in sorted(set(spec) & set(ours)):
        if spec[name] != ours[name]:
            errors.append(f"interrupt source {name}: registers.md gives {spec[name]}, regmap.def {ours[name]}")
    return errors


def check_quoted_values(symbols, docs, required):
    """Every `NAME` = `value` the specs quote must match the generated value.
    In `required` files (registers.md) the name must also exist."""
    errors = []
    values = {s.name: s.value for s in symbols if s.name}
    pat = re.compile(r"`([A-Z][A-Z0-9_]*)` = `?(0x[0-9A-Fa-f]+|\d+)\b")
    for path, text in docs:
        for m in pat.finditer(text):
            name, value = m.group(1), int(m.group(2), 0)
            if name not in values:
                if path in required:
                    errors.append(f"{path.name} quotes {name} = {m.group(2)}, but regmap.def does not make {name}")
                continue
            if values[name] != value:
                errors.append(f"{path.name} quotes {name} = {m.group(2)}, regmap.def gives 0x{values[name]:X}")
    return errors


# ---------------------------------------------------------------- the generated names

@dataclass
class Sym:
    name: str     # None for a heading line
    value: int = 0
    comment: str = ""


def symbols(rm):
    """The names hw.inc and hw.h define, in order."""
    out = []
    seen = {}

    def eq(name, value, comment=""):
        if name in seen:
            raise DefError(f"generated name {name} is defined twice")
        seen[name] = value
        out.append(Sym(name, value, comment))

    def heading(text):
        out.append(Sym(None, 0, text))

    def fields(prefix, flds):
        for f in flds:
            eq(f"{prefix}_{f.name}_B", f.lo)
            eq(f"{prefix}_{f.name}_W", f.width)
            eq(f"{prefix}_{f.name}_M", f.mask)

    def register(b, name, offset, width, comment):
        eq(name, offset, comment)
        eq(f"{name}_N", width)
        if b.io:
            eq(f"{name}_P", b.port(offset))
        if width > 1:
            for i in range(width):
                bn = byte_name(name, i)
                eq(bn, offset + i)
                if b.io:
                    eq(f"{bn}_P", b.port(offset + i))

    def desc(access, flags, spec):
        return ",".join([access] + sorted(flags)) + f", spec {spec}"

    for b in rm.blocks:
        heading(f"{b.name}: {b.text}")
        eq(f"{b.name}_SIZE", b.size)
        for r in b.regs:
            register(b, r.name, r.offset, r.width, desc(r.access, r.flags, r.spec))
            fields(r.name, r.fields)
        for rl in b.reglists:
            eq(rl.name, rl.offset, f"{rl.name}0..{rl.count - 1}, spec {rl.spec}")
            eq(f"{rl.name}_NUM", rl.count)
            fields(rl.name, rl.fields)
            for i in range(rl.count):
                register(b, byte_name(rl.name, i), rl.offset + i * rl.width, rl.width,
                         desc(rl.access, rl.flags, rl.spec))
        for g in b.groups:
            gen = g.generic
            heading(f"{g.elem(0)}..{g.elem(g.count - 1)}: {g.count} x 0x{g.stride:X} bytes, spec {g.spec}")
            eq(f"{gen}_NUM", g.count)
            eq(f"{gen}_SPAN", g.stride)
            whole = len(g.regs) == 1 and g.regs[0].name == "-"
            for r in g.regs:
                if r.name == "-":
                    fields(gen, r.fields)
                    continue
                eq(f"{gen}_{r.name}", r.offset, f"{desc(r.access, r.flags, r.spec)} (add to {gen}n)")
                eq(f"{gen}_{r.name}_N", r.width)
                if r.width > 1:
                    for i in range(r.width):
                        eq(byte_name(f"{gen}_{r.name}", i), r.offset + i)
                fields(f"{gen}_{r.name}", r.fields)
            for n in range(g.count):
                base = g.base + n * g.stride
                if not whole:
                    eq(g.elem(n), base)
                    if b.io:
                        eq(f"{g.elem(n)}_P", b.port(base))
                for r in g.regs:
                    name = g.elem(n) if r.name == "-" else f"{g.elem(n)}_{r.name}"
                    register(b, name, base + r.offset, r.width,
                             desc(r.access, r.flags, r.spec) if r.name == "-" else "")
        for a in b.areas:
            eq(f"{b.name}_{a.name}", a.offset, f"{a.access}, spec {a.spec}")
            eq(f"{b.name}_{a.name}_SIZE", a.size)
    heading("Low-byte-only ports: answer whatever the high byte holds")
    for p in rm.ports:
        eq(f"{p.name}_PORT", p.lowbyte)
    heading("Named numbers")
    for c in rm.consts:
        eq(c.name, c.value, c.text)
    heading("Interrupt sources: INTB_name is the bit and INTR_name the byte (INTENA0 + INTR_name)")
    for c in rm.consts:
        if c.name.startswith("INT_") and 0 <= c.value < INT_SOURCES:
            src = c.name[4:]
            eq(f"INTB_{src}", c.value % 7)
            eq(f"INTR_{src}", c.value // 7)
    return out


# ---------------------------------------------------------------- output

HEADER = "Generated by tools/regmap.py from fpga/regmap.def. Do not edit; edit regmap.def and rerun."


def gen_asm(syms):
    out = [f"; {HEADER}",
           "; sjasmplus equates for retro-z80 (spec 3, section 8).",
           ";",
           "; A system register's name is its register number, a custom register's its custom",
           "; offset; both are also the register page offset (custom: REGS_CUSTOM + name).",
           "; name_P is the port (ld bc,name_P / out (c),a), name_N the width in bytes.",
           "; Bytes of a wider register: NAME0..NAME3 (NAME_0.. where NAME ends in a digit).",
           "; Fields: NAME_F_B = lowest bit, NAME_F_W = width, NAME_F_M = mask, in the whole value.",
           "; Arrays: G_NUM, G_SPAN, Gn (where element n starts), G_REG (offset in an element),",
           ";   Gn_REG and Gn_REG_P (ready-added).",
           ";",
           "; sjasmplus has no function-like defines (spec 3, open point R1), so there is no",
           "; CPORT(off) here. Write a computed custom port out:",
           ";   ((off & 0xFF) << 8) | 0x10 | (off >> 8)",
           ""]
    for s in syms:
        if s.name is None:
            out += ["", f"; ---- {s.comment}"]
            continue
        line = f"{s.name:<28} equ 0x{s.value:X}"
        if s.comment:
            line = f"{line:<46} ; {s.comment}"
        out.append(line)
    return "\n".join(out) + "\n"


def gen_c(syms):
    out = [f"/* {HEADER} */",
           "/* C header for retro-z80 (z88dk); the same names as hw.inc (spec 3, section 8). */",
           "",
           "#ifndef RETROZ80_HW_H",
           "#define RETROZ80_HW_H",
           "",
           "/* The port of a custom offset (spec 3, section 5). */",
           "#define CPORT(off) (((((unsigned)(off)) & 0xFFu) << 8) | (0x10u + (((unsigned)(off)) >> 8)))",
           ""]

    def u(v):
        return f"0x{v:X}u" if v <= 0xFFFF else f"0x{v:X}UL"

    for s in syms:
        if s.name is None:
            out += ["", f"/* ---- {s.comment} */"]
            continue
        line = f"#define {s.name:<28} {u(s.value)}"
        if s.comment:
            line = f"{line:<48} /* {s.comment} */"
        out.append(line)
    out += ["", "#endif /* RETROZ80_HW_H */"]
    return "\n".join(out) + "\n"


def ranges(addrs):
    """Sorted addresses as (first, last) runs."""
    out = []
    for a in sorted(set(addrs)):
        if out and out[-1][1] == a - 1:
            out[-1][1] = a
        else:
            out.append([a, a])
    return out


def decode(addrs, var="a", width=13):
    terms = []
    digits = (width + 3) // 4
    for lo, hi in ranges(addrs):
        if lo == hi:
            terms.append(f"(({var}) == {width}'h{lo:0{digits}X})")
        else:
            terms.append(f"(({var}) >= {width}'h{lo:0{digits}X} && ({var}) <= {width}'h{hi:0{digits}X})")
    return "(" + (" || ".join(terms) if terms else "1'b0") + ")"


def gen_verilog(rm):
    out = [f"// {HEADER}",
           "// Verilog defines for the retro-z80 register decoders (spec 3).",
           "//",
           "// Addresses are register bus addresses, 13 bits: the register page offset,",
           "// page << 8 | register for a port, 0x1000 + offset for the custom block.",
           "//   `RM_name        a register's (or a byte's) bus address",
           "//   `RM_name_BYTES  its width in bytes (name_N in hw.inc)",
           "//   `RM_name_FIELD  a field's bits in the whole value, e.g. value[`RM_SDCON_CLKDIV]",
           "//   `RM_G_BASE, `RM_G_SPAN, `RM_G_NUM, `RM_G_REG   arrays: element 0, stride, count,",
           "//                  and a register's offset in an element",
           "// Decodes, true for a 13-bit bus address a (or a port's low byte lo):",
           "//   `RM_IS_CAP(a), `RM_CAP_N(a)   the low byte of a capturing register, and its width (rule 4)",
           "//   `RM_IS_COLR(a), `RM_IS_COLR_RED(a)   a colour register's bytes, and its committing red byte (rule 7)",
           "//   `RM_IS_MMU(a), `RM_IS_MMU_COMMIT(a)  an MMU page register's bytes, and its committing byte 1",
           "//   `RM_IS_IPG(a), `RM_IS_IPG_COMMIT(a)  the same for the interrupt pages (page 0x01)",
           "//   `RM_IS_SC(a)    a set/clear register's bytes (rule 12)",
           "//   `RM_IS_LOWPORT(lo)   a low-byte-only port",
           "",
           "`ifndef RETROZ80_REGMAP_VH",
           "`define RETROZ80_REGMAP_VH",
           ""]
    seen = set()

    def d(name, value):
        if name in seen:
            raise DefError(f"generated Verilog name RM_{name} is defined twice")
        seen.add(name)
        out.append(f"`define RM_{name:<30} {value}")

    def fields(prefix, flds):
        for f in flds:
            d(f"{prefix}_{f.name}", f"{f.hi}:{f.lo}" if f.width > 1 else f"{f.lo}")

    def a13(v):
        return f"13'h{v:04X}"

    def register(b, name, offset, width):
        d(name, a13(b.bus(offset)))
        d(f"{name}_BYTES", width)
        if width > 1:
            for i in range(width):
                d(byte_name(name, i), a13(b.bus(offset + i)))

    for b in rm.blocks:
        out += ["", f"// ---- {b.name}: {b.text}"]
        d(f"{b.name}_BASE", a13(b.bus(0)))
        d(f"{b.name}_SIZE", f"14'h{b.size:04X}")
        for r in b.regs:
            register(b, r.name, r.offset, r.width)
            fields(r.name, r.fields)
        for rl in b.reglists:
            d(rl.name, a13(b.bus(rl.offset)))
            d(f"{rl.name}_NUM", rl.count)
            fields(rl.name, rl.fields)
            for i in range(rl.count):
                register(b, byte_name(rl.name, i), rl.offset + i * rl.width, rl.width)
        for g in b.groups:
            gen = g.generic
            d(f"{gen}_BASE", a13(b.bus(g.base)))
            d(f"{gen}_SPAN", f"8'h{g.stride:02X}")
            d(f"{gen}_NUM", g.count)
            for r in g.regs:
                if r.name == "-":
                    d(f"{gen}_BYTES", r.width)
                    fields(gen, r.fields)
                    continue
                d(f"{gen}_{r.name}", f"8'h{r.offset:02X}")
                d(f"{gen}_{r.name}_BYTES", r.width)
                fields(f"{gen}_{r.name}", r.fields)
        for a in b.areas:
            d(f"{b.name}_{a.name}", a13(b.bus(a.offset)))
            d(f"{b.name}_{a.name}_SIZE", f"14'h{a.size:04X}")

    flat = [f for f in flat_registers(rm) if f.block.io]
    cap = [f for f in flat if "CAP" in f.flags]
    colr = [f for f in flat if "COLR" in f.flags]
    mmu = [f for f in flat if "MMU" in f.flags and f.block.page == 0x00]
    ipg = [f for f in flat if "MMU" in f.flags and f.block.page != 0x00]
    sc = [f for f in flat if f.access == "SC"]

    def all_bytes(fs):
        return [f.block.bus(f.offset + i) for f in fs for i in range(f.width)]

    out += ["", "// ---- Decodes"]
    d("IS_CAP(a)", decode([f.block.bus(f.offset) for f in cap]))
    capn = "3'd0"
    for f in reversed(sorted(cap, key=lambda f: f.block.bus(f.offset))):
        capn = f"((a) == {a13(f.block.bus(f.offset))} ? 3'd{f.width} : {capn})"
    d("CAP_N(a)", f"({capn})")
    d("IS_COLR(a)", decode(all_bytes(colr)))
    d("IS_COLR_RED(a)", decode([f.block.bus(f.offset + f.width - 1) for f in colr]))
    d("IS_MMU(a)", decode(all_bytes(mmu)))
    d("IS_MMU_COMMIT(a)", decode([f.block.bus(f.offset + 1) for f in mmu]))
    d("IS_IPG(a)", decode(all_bytes(ipg)))
    d("IS_IPG_COMMIT(a)", decode([f.block.bus(f.offset + 1) for f in ipg]))
    d("IS_SC(a)", decode(all_bytes(sc)))
    d("IS_LOWPORT(lo)", decode([p.lowbyte for p in rm.ports], "lo", 8))

    out += ["", "// ---- Low-byte-only ports"]
    for p in rm.ports:
        d(f"{p.name}_PORT", f"8'h{p.lowbyte:02X}")
    out += ["", "// ---- Named numbers"]
    for c in rm.consts:
        d(c.name, f"32'h{c.value:08X}")
    out += ["", "`endif", ""]
    return "\n".join(out)


# ---------------------------------------------------------------- main

def run(def_file, spec_file, out_root, verify):
    """Check, then write (or with verify, compare) the generated files. Returns an exit code."""
    try:
        rm = parse(Path(def_file).read_text(encoding="utf-8"))
    except DefError as e:
        print(f"regmap.def: {e}", file=sys.stderr)
        return 1
    errors = check(rm)
    spec_file = Path(spec_file)
    md = spec_file.read_text(encoding="utf-8")
    errors += check_spec(rm, md)
    try:
        syms = symbols(rm)
        outputs = {OUT_ASM: gen_asm(syms), OUT_C: gen_c(syms), OUT_V: gen_verilog(rm)}
    except DefError as e:
        errors.append(str(e))
        syms = []
        outputs = {}
    docs = [(p, p.read_text(encoding="utf-8")) for p in sorted(spec_file.parent.glob("*.md"))]
    guide = spec_file.parent.parent / "guide"
    docs += [(p, p.read_text(encoding="utf-8")) for p in sorted(guide.glob("*.md"))]
    errors += check_quoted_values(syms, docs, {spec_file})
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1

    stale = []
    for rel, text in outputs.items():
        path = Path(out_root) / rel
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == text:
            continue
        if verify:
            stale.append(rel)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", newline="\n")
            print(f"wrote {rel.as_posix()}")
    if stale:
        for rel in stale:
            print(f"out of date: {rel.as_posix()} (run python3 tools/regmap.py)", file=sys.stderr)
        return 1
    n = len([f for f in flat_registers(rm) if f.block.name in CHECKED])
    print(f"regmap OK: {n} registers checked against {spec_file.name}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify", action="store_true", help="fail if generated files are out of date (do not write)")
    ap.add_argument("--def", dest="def_file", default=DEF_FILE, help="the definition file (default fpga/regmap.def)")
    ap.add_argument("--spec", default=SPEC_FILE, help="spec 3 (default docs/spec/registers.md)")
    ap.add_argument("--out", default=ROOT, help="root for the generated files (default the repository)")
    args = ap.parse_args(argv)
    return run(args.def_file, args.spec, args.out, args.verify)


if __name__ == "__main__":
    sys.exit(main())
