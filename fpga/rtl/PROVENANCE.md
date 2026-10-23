# Provenance

Modules and files copied from [retro68k](https://github.com/jonsole/retro68k) (design plan, branch 12, "RTL reuse"). Copy only from a committed retro68k state. Later retro68k fixes are ported by hand: compare its git log since the commit below.

| File here | From retro68k | retro68k commit | What was changed |
|-----------|---------------|-----------------|------------------|
| `tools/bin2hex.py` | `tools/bin2hex.py` | 57e7f6d | Writes little-endian words |
| `tools/regmap.py` | `tools/regmap.py` | 57e7f6d | Byte registers with a width (1–4 bytes) in place of 32-bit words; I/O pages with ports (`_P`), custom offsets and register page offsets; byte names NAME0–NAME3 (spec 3, section 8); `regs` with a width and fields, `port`, element arrays (`MMU`, `MMUnW`); access flags; copper MOVE reach check; `INTB_`/`INTR_` names; sjasmplus `hw.inc`, a C `hw.h` with the same names and `CPORT`, a `regmap.vh` with bus addresses and decodes; `--verify` reads spec 3's tables, ports, register page and interrupt sources, and quoted values; `--def`, `--spec` and `--out` for the self-test. `struct` left out |
