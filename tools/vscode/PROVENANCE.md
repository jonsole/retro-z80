# Provenance

Files copied from the zx emulator's extension (`jonsole/zx-spectrum-emulator`, `vscode-extension/`, commit `f8d979e`, MIT licence, the same author). This extension is shaped like that one (design plan, branch 20).

| File | Changes |
|------|---------|
| `asm_language.js`, `asm_index.js`, `asm_doc.js` | None |
| `syntaxes/z80-asm.tmLanguage.json`, `language-configuration.json` | None |
| `sjasmplus_fetch.js` | The download's User-Agent. The pinned sjasmplus is the emulator's (1.23.1, with its SHA-256s); CI builds 1.24.0 |
| `server_registry.js` | The bridge's adverts: `RZ80_BRIDGE_ADVERT_DIR`, `retro-z80/bridges`, ports `dap`, `mcp`, `console`, and the serial port; its names and details |
| `tests/asm_doc_test.js`, `tests/asm_index_test.js` | The tests of the emulator's own sources replaced by one on `firmware/boot/` |
| `tests/sjasmplus_fetch_test.js` | The check against the emulator's `scripts/fetch_sjasmplus.py` left out |
| `tests/server_registry_test.js` | The bridge's adverts |

Adapted (rewritten from the emulator's, same shape): `bridge_launch.js` and `bridge_view.js` (from `server_launch.js` and `server_view.js`), `watchpoint_model.js` and `watchpoint_view.js`. New: `extension.js`, `console_terminal.js`, `program_view.js`, `rimg.js`, `build_task.js`, `task_provider.js`, `tests/harness.js` and the other tests.
