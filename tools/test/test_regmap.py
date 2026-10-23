#!/usr/bin/env python3
"""Self-test of tools/regmap.py: the real definition verifies, and broken ones fail.

Run: python3 tools/test/test_regmap.py   (or make -C tools check)
"""

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import regmap  # noqa: E402

DEF = (ROOT / "fpga" / "regmap.def").read_text(encoding="utf-8")
SPEC = ROOT / "docs" / "spec" / "registers.md"


def run(def_text=DEF, spec_text=None, out=ROOT, verify=True):
    """Run the generator on the given texts; return (exit code, stderr)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        d = tmp / "regmap.def"
        d.write_text(def_text, encoding="utf-8")
        spec = SPEC
        if spec_text is not None:
            # keep the other specs beside it, as the quoted-value check reads them
            (tmp / "spec").mkdir()
            for p in SPEC.parent.glob("*.md"):
                (tmp / "spec" / p.name).write_text(p.read_text(encoding="utf-8"), encoding="utf-8")
            spec = tmp / "spec" / "registers.md"
            spec.write_text(spec_text, encoding="utf-8")
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = regmap.run(d, spec, out, verify)
        return code, err.getvalue()


def broken(old, new, count=1):
    assert DEF.count(old) == count, f"test is stale: {old!r} appears {DEF.count(old)} times in regmap.def"
    return DEF.replace(old, new)


class RealFiles(unittest.TestCase):
    def test_definition_matches_spec_and_generated_files(self):
        code, err = run()
        self.assertEqual(code, 0, err)

    def test_stale_generated_file_fails(self):
        with tempfile.TemporaryDirectory() as out:
            self.assertEqual(run(out=out, verify=False)[0], 0)
            self.assertEqual(run(out=out)[0], 0)
            hw = Path(out) / "firmware" / "include" / "hw.inc"
            hw.write_text(hw.read_text(encoding="utf-8") + "; edited by hand\n", encoding="utf-8")
            code, err = run(out=out)
            self.assertEqual(code, 1)
            self.assertIn("out of date", err)


class BrokenDefinition(unittest.TestCase):
    """Each deliberate mistake in regmap.def must fail verify, with a message naming it."""

    CASES = [
        ("register moved", "reg  0x70 SYSID    1 R", "reg  0x6F SYSID    1 R", "SYSID"),
        ("register dropped", "reg  0x0C INTID    1 R       8/6    SRC=4:0\n", "", "INTID"),
        ("register renamed", "reg  0x0D NMICON ", "reg  0x0D NMICTRL", "NMICON"),
        ("wrong width", "reg  0x20 TIME     4 R,CAP", "reg  0x20 TIME     2 R,CAP", "TIME"),
        ("wrong access", "reg  0x0E NMISTAT  1 W1C", "reg  0x0E NMISTAT  1 RW ", "NMISTAT"),
        ("capture flag lost", "reg  0x5D SDCOUNT  2 RW,CAP", "reg  0x5D SDCOUNT  2 RW    ", "SDCOUNT"),
        ("overlap", "reg  0x49 WDTIME   2 RW,LOCK", "reg  0x49 WDTIME   3 RW,LOCK", "overlaps"),
        ("field outside the width", "reg  0x77 CPUSPEED 1 RW      7/6.1  DIV=2:0 SPECTRUM=3",
         "reg  0x77 CPUSPEED 1 RW      7/6.1  DIV=2:0 SPECTRUM=8", "outside"),
        ("fields overlap", "PRIO     1 RW      4/4.8  FRONT=1:0", "PRIO     1 RW      4/4.8  FRONT=2:0", "overlaps"),
        ("group register moved", "  reg 0xB CTL      1 RW", "  reg 0xA CTL      1 RW", "SPR"),
        ("group stride", "array L 3 0x090 0x20", "array L 3 0x090 0x24", "L"),
        ("element count", "array DMX 4 0x140", "array DMX 3 0x140", "CHCTRL"),
        ("beyond copper MOVE", "array SPR 8 0x010 0x10", "array SPR 8 0x070 0x10", "copper"),
        ("low-byte port", "port SDDATA   0x5B 0x5B", "port SDDATA   0x5A 0x5A", "0x5"),
        ("interrupt number", "const INT_KEYB    17", "const INT_KEYB    16", "INT_KEYB"),
        ("interrupt dropped", "const INT_SOFT    18\n", "", "INT_SOFT"),
        ("register page area", "area PALETTE2   0x1A00", "area PALETTE2   0x1B00", "0x1A00"),
        ("quoted value", "const REGS_PAL_SPAN 0x300 ", "const REGS_PAL_SPAN 0x400 ", "REGS_PAL_SPAN"),
        ("duplicate name", "reg  0x79 I2CDATA ", "reg  0x79 I2CCON  ", "twice"),
        ("syntax", "reg  0x7B I2CSTAT  1 R ", "reg  0x7B I2CSTAT  1 Q ", "access"),
    ]

    def test_each_mistake_fails(self):
        for what, old, new, expect in self.CASES:
            with self.subTest(what):
                code, err = run(broken(old, new))
                self.assertEqual(code, 1, f"{what}: verify passed a broken definition")
                self.assertIn(expect, err)


class BrokenSpec(unittest.TestCase):
    """A spec table that disagrees with regmap.def must fail verify too."""

    def test_spec_row_changed(self):
        spec = SPEC.read_text(encoding="utf-8")
        old = "| `0x7B` | `0x7B00` | I2CSTAT | 1 | R |"
        self.assertIn(old, spec)
        code, err = run(spec_text=spec.replace(old, "| `0x7B` | `0x7B00` | I2CSTAT | 1 | RW |"))
        self.assertEqual(code, 1)
        self.assertIn("I2CSTAT", err)

    def test_spec_quoted_value_changed(self):
        spec = SPEC.read_text(encoding="utf-8")
        old = "`SYSID_P` = `0x7000`"
        self.assertIn(old, spec)
        code, err = run(spec_text=spec.replace(old, "`SYSID_P` = `0x7100`"))
        self.assertEqual(code, 1)
        self.assertIn("SYSID_P", err)


class Names(unittest.TestCase):
    """Spec 3, section 8's naming rules, from the generated names."""

    @classmethod
    def setUpClass(cls):
        rm = regmap.parse(DEF)
        cls.syms = {s.name: s.value for s in regmap.symbols(rm) if s.name}

    def test_byte_names(self):
        for name, value in [("TIME0", 0x20), ("TIME3", 0x23), ("SDCON1", 0x59), ("WDTIME1", 0x4A),
                            ("SPRDMA1", 0x121), ("TMR0_COUNT0", 0x2D), ("SPR0_PT0", 0x010),
                            ("L1_BPL0PT2", 0x0C6), ("DMX2_CHDESC0", 0x1E0),
                            ("MMU0_0", 0x80), ("MMU0_1", 0x81), ("MMU0W_0", 0x90), ("MMU0W_1", 0x91)]:
            self.assertEqual(self.syms.get(name), value, name)
        for missing in ("MMU00", "MMU0W0", "TIMEL", "SDCONH"):
            self.assertNotIn(missing, self.syms)

    def test_ports(self):
        for name, value in [("SYSID_P", 0x7000), ("BGCOLOR_P", 0x0410), ("SPR0_PT_P", 0x1010),
                            ("COPCON_P", 0x0011), ("DMX3_CTRL_P", 0x0012), ("MMU0W_1_P", 0x9100),
                            ("SERDATA_PORT", 0x53), ("ULA_PORT", 0xFE), ("KBDATA_PORT", 0x62)]:
            self.assertEqual(self.syms.get(name), value, name)
        self.assertNotIn("KEYROW0_P", self.syms)  # the register page has no ports

    def test_interrupt_names(self):
        self.assertEqual((self.syms["INTB_SERIAL"], self.syms["INTR_SERIAL"]), (1, 2))
        self.assertNotIn("INTB_NONE", self.syms)


if __name__ == "__main__":
    unittest.main()
