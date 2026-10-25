"""sjasmplus SLD files: source lines, labels and pages (debug.md, section 7.2).

One record per line, `file|line|deffile|defline|page|value|type|data`.
T: an instruction's address and line. F: a label. D: an EQU (often not an
address). Z: the device; with `pages.size:8192` the page field is an 8 KB
page, which the bridge uses as the breakpoint's PAGE (the MMU page the
window must hold) for code in a banked window. With no device the page is -1.

The same rules as the zx emulator's parser (cpp-core/src/rom_source.cpp),
with 8 KB pages instead of the 128K's 16 KB banks.
"""

import bisect
import os


def _int(s):
    try:
        return int(s.split(":")[0])
    except ValueError:
        return None


class SourceFile:
    def __init__(self, sld_name, path):
        self.sld_name = sld_name
        self.path = path
        self.line_to_addr = {}     # line -> address (first wins)
        self.line_to_page = {}

    def lines(self):
        return sorted(self.line_to_addr)


class Symbols:
    def __init__(self):
        self.files = []
        self.addr_to_loc = {}      # address -> (file index, line)
        self.symbols = {}          # name -> address
        self.equates = set()
        self.symbol_pages = {}
        self.paged = False
        self.sld_path = None
        self._sorted = None

    # ------------------------------------------------------------ loading
    @classmethod
    def load(cls, sld_path, base_dir=None):
        with open(sld_path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        s = cls()
        s.sld_path = os.path.abspath(sld_path)
        s.parse(text, base_dir or os.path.dirname(s.sld_path))
        return s

    def _file(self, name, base_dir):
        for i, f in enumerate(self.files):
            if f.sld_name == name:
                return i
        if os.path.isabs(name) or (len(name) > 2 and name[1] == ":") or not base_dir:
            path = name
        else:
            path = os.path.join(base_dir, name)
        self.files.append(SourceFile(name, os.path.normpath(path)))
        return len(self.files) - 1

    def parse(self, text, base_dir):
        paged = []
        for line in text.splitlines():
            fields = line.split("|")
            if len(fields) < 8:
                continue
            fname, line_s, _, _, page_s, addr_s, rtype, data = fields[:8]
            page = _int(page_s)
            page = page if page is not None and page >= 0 else None
            if rtype == "Z":
                self.paged = "pages.size:8192" in data
                continue
            addr = _int(addr_s)
            if rtype == "T":
                ln = _int(line_s)
                if ln is None or addr is None or not 0 <= addr <= 0xFFFF:
                    continue
                fi = self._file(fname, base_dir)
                f = self.files[fi]
                f.line_to_addr.setdefault(ln, addr)
                self.addr_to_loc.setdefault(addr, (fi, ln))
                paged.append((page, fi, ln, None))
            elif rtype in ("F", "D") and data:
                if addr is None or not 0 <= addr <= 0xFFFF:
                    continue
                self.symbols[data] = addr
                if rtype == "D":
                    self.equates.add(data)
                else:
                    self.equates.discard(data)
                    paged.append((page, None, None, data))
        if self.paged:
            for page, fi, ln, name in paged:
                if page is None:
                    continue
                if name is not None:
                    if name not in self.equates:
                        self.symbol_pages[name] = page
                else:
                    self.files[fi].line_to_page.setdefault(ln, page)
        self._sorted = None

    # ------------------------------------------------------------ lookups
    def find_file(self, path):
        """A source file by path (case-insensitive on Windows paths), or by bare name."""
        if not path:
            return None
        want = os.path.normcase(os.path.normpath(path))
        for f in self.files:
            if os.path.normcase(f.path) == want:
                return f
        base = os.path.basename(path).lower()
        hits = [f for f in self.files if os.path.basename(f.path).lower() == base]
        return hits[0] if len(hits) == 1 else None

    def line_address(self, path, line):
        """A source line -> (address, page, actual line), moving to the next line with code."""
        f = self.find_file(path)
        if f is None:
            return None
        lines = f.lines()
        i = bisect.bisect_left(lines, line)
        if i >= len(lines):
            return None
        ln = lines[i]
        return f.line_to_addr[ln], f.line_to_page.get(ln), ln

    def location(self, addr):
        """An address -> (path, line), or None."""
        loc = self.addr_to_loc.get(addr & 0xFFFF)
        if loc is None:
            return None
        return self.files[loc[0]].path, loc[1]

    def _sorted_symbols(self):
        if self._sorted is None:
            pairs = sorted((a, n) for n, a in self.symbols.items() if n not in self.equates)
            self._sorted = ([a for a, _ in pairs], [n for _, n in pairs])
        return self._sorted

    def symbol_at(self, addr, max_offset=None):
        addrs, names = self._sorted_symbols()
        i = bisect.bisect_right(addrs, addr) - 1
        if i < 0:
            return None
        off = addr - addrs[i]
        if max_offset is not None and off > max_offset:
            return None
        return names[i], off

    def resolve(self, name):
        if name in self.symbols:
            return self.symbols[name]
        low = name.lower()
        hits = [a for n, a in self.symbols.items() if n.lower() == low]
        return hits[0] if len(hits) == 1 else None
