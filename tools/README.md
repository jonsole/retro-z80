# Tools

| Tool | What it does |
|------|--------------|
| `bin2hex.py` | Turns a binary (the boot ROM, a test image) into a `$readmemh` file of 16-bit little-endian words, as the SRAM and boot ROM hold them (spec 2). Adapted from retro68k's, which writes big-endian words |

Only the Python standard library is needed.
