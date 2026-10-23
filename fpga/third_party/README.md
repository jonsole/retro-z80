# Third-party code

Cores and libraries written by others, each in its own folder with its licence. Files are copied unchanged; changes, when needed, go in our own files (as `fpga/rtl/z80_cpu.v` will replace the `tv80s` wrapper, spec 1).

| Folder | What | From | Upstream commit | Licence |
|--------|------|------|-----------------|---------|
| `tv80/` | tv80 Z80 core by Guy Hutchison, a Verilog version of Daniel Wallner's T80 | [github.com/hutch31/tv80](https://github.com/hutch31/tv80), `rtl/core/` | `66a131c` (2026-05-11) | MIT (`tv80/LICENSE`, and the header of every file) |

## tv80

Copied: `tv80_core.v`, `tv80_alu.v`, `tv80_mcode.v`, `tv80_reg.v` (the core), `tv80s.v` (the synchronous wrapper, used bare by `sim/zex/`) and `tv80n.v` (the wrapper with negative-edge strobes, for reference), and the upstream `LICENSE`. Not copied: the test environment, the other `rtl/` folders (UART, GMII, Wishbone, scoreboard adapters) and the Docker tools.

The licence is the MIT licence (copyright 2004 Guy Hutchison), not BSD-style as the design plan first said. It allows use, change and redistribution, with the copyright and permission notice kept.

The upstream commit includes the May 2026 fixes for DAA parity and the CPI/CPD undocumented flags (upstream `59d343e`), found with a ZEXALL-like test (exz80all). Older copies (OpenCores, 2004–2019) do not have them. To update: compare upstream's `git log -- rtl/core` since the commit above, copy the files again and run `make -C sim zexdoc zexall`.

`sim/zex/` holds ZEXDOC and ZEXALL themselves (GPL v2, see there); they are test programs, not part of the design.
