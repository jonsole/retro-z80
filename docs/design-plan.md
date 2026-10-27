# retro-z80 design plan

Status: **draft for review**. The decisions below were made one by one (section 1), and every block now has a draft spec in [`spec/`](spec/) (section 4). Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the specs are agreed.

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a **new machine** (not a copy of an existing one) for use both as a home computer and as a games machine. It runs on the same board, the **ZX Spectrum Next KS3**, with the same video output, storage and USB link, but with a Z80 and a smaller chipset made for an 8-bit CPU. The chipset is kept separate from the CPU, so a 6502 version stays possible; it will be its own machine in its own repo (branch 8).

## 1. Decision tree

| # | Branch | Decision |
|---|--------|----------|
| 1 | Board | ZX Spectrum Next KS3, the Z80 as a soft core in its FPGA |
| 1 | Compatibility | A new machine; Spectrum games are made easy to port, not run unchanged |
| 1 | Use | Both home computer and games machine |
| 1 | Chipset | ~~New and scaled down for an 8-bit CPU~~ retro68k's chipset narrowed to 8 bits (branch 9) |
| 2 | CPU core | tv80 (Verilog) |
| 2 | CPU speed | 3.5, 7, 14 or 28 MHz by software; **28 MHz after reset** |
| 2 | Interrupts | IM 2 with vectors from the interrupt controller (IM 1 also works) |
| 2 | Memory | Eight 8 KB windows onto the SRAM (MMU) |
| 3 | Picture | 360×288 at 2×, filling the 576p screen; every layer has its own size and position, so a 256×192 window can be placed |
| 3 | Layers | ~~Background colour, a bitmap layer, a tile layer, an attribute layer, sprites~~ see branch 9 |
| 3 | Bitmap | ~~1, 2, 4 or 8 bits per pixel~~ see branch 9 |
| 3 | Tiles | ~~8×8, 1, 2, 4 or 8 bits per pixel (1-bit for text)~~ see branch 9 |
| 3 | Hi-res | ~~Per layer: 720 across instead of 360~~ see branch 9 |
| 3 | Lines | ~~Per layer: 288 lines (each shown twice) or 576; output stays 576p (not 576i)~~ see branch 9 |
| 3 | Display fetch | ~~A FIFO per source just ahead of drawing; 288-line layers replay their first line from a repeat buffer~~ see branch 9 |
| 3 | Colours | ~~12-bit RGB (4096 colours); palette grown to 512 entries for the attribute layer~~ see branch 9 |
| 3 | Attributes | ~~An attribute layer of 8×8 or 8×1 cells that sets the palette bank of the bitmap or the tile layer~~ see branch 9 |
| 3 | Spectrum screen layout | Done by the copper (a line address per line), no extra hardware |
| 3 | Copper | ~~In version 1, a "smart" copper: loops, a counter, indirect moves through X/Y pointers~~ see branch 9 |
| 4 | Sprites | ~~32 sprites, 8 to 32 pixels, 1, 2, 4 or 8 bits per pixel, patterns in SRAM~~ see branch 9 |
| 4 | Sprite scaling | ~~Fractional, X and Y separately, 1/16× to 16× (16-bit steps, 4.12 fixed point)~~ see branch 9 |
| 5 | Sound | ~~**Open** (Q1)~~ see branch 9 |
| 6 | Registers | 8-bit, in Z80 I/O space and also as memory through a register page any window can map; 16- and 24-bit values are byte groups latched on the last byte |
| 6 | MMU read/write | Each window has a read page and a write page; setting the read page also sets the write page; ROM, RAM or registers in any window |
| 6 | DMA engine | ~~Later~~ see branch 9 |
| 7 | BASIC | BBC BASIC (Z80) |
| 7 | CP/M | Later (CP/M 3) |
| 7 | I/O | USB serial (FT232H), SD card, PS/2 keyboard, joysticks, Spectrum keyboard |
| 7 | Assembler | sjasmplus |
| 8 | 6502 | ~~Decide later~~ **Its own repo** (a sister machine, as retro68k is), sharing this chipset. Keep the chipset CPU-independent; the 6502 repo copies it from a committed, tested state, as retro-z80 copies retro68k |
| 9 | Direction | **retro-z80 is retro68k narrowed to 8 bits:** the same blocks, register names, bit layouts and programming model, cut to 8-bit ports. It differs only where the Z80 (8-bit ports, 64 KB address space, IM 2 on one /INT line) or the memory bandwidth (448 guaranteed display bytes per line against retro68k's 1,280) forces it. Every spec has a "Comparison with retro68k" table listing each difference and why |
| 9 | Layers | Background colour, **two identical layers L0 and L1** with retro68k's per-layer register block (CTRL, window, pointer, stride, scroll), each a **bitmap or a tile map** (a CTRL mode field), and retro68k's PRIO register. Bitmaps chunky 1/2/4/8 bpp; tiles 8×8 at 1/2/4/8 bpp. Scale 1× or 2× across and down (retro68k's HSCALE/VSCALE fields, 4× and 8× reserved). Kept inside the hardware for bandwidth: the FIFOs and the repeat buffer |
| 9 | Palettes | As retro68k: a 256-entry palette per layer and one for the sprites, with PALOFS and VIDCON.SHAREPAL. Colours stay 12-bit RGB (the KS3's VGA has 4 bits per colour) |
| 9 | Sprites | **retro68k's 8 sprites:** SPRxPT, SPRxH, SPRxV, SPRxCTL; any size (a window per sprite), 2/4/8 bpp, magnify ×1/2/4 across and down, DEPTH among the layers, own palette, collisions. Fetched whole rows into a line buffer inside, for bandwidth. Fractional scaling, flips and the attribute table are dropped |
| 9 | Copper | **retro68k's copper instructions and names in 16-bit words with 8-bit data:** MOVE is one word (register and 8-bit data); WAIT, SKIP and JUMP take two; MOVR, the ALU (8-bit R0–R7, flags Z N C), SKIPC, CALL/RET; COP1LC/COP2LC, COPJMP1/2, COPCON. Same macros as retro68k |
| 9 | DMA engine | retro68k's DMA engine (its version-1 decision), narrowed: one channel, copy and fill in 1D and 2D, SRAM only, spare memory cycles. Specified now |
| 9 | Sound | Still parked (Q1); its ports and interrupt reserved under retro68k's names |
| 9 | Interrupts | retro68k's model: each unit keeps its own flags and enables; the controller has INTCON.MASTER, INTENA (set/clear), INTPEND, INTRAW, VECBASE, SOFTINT, NMICON, NMISTAT; retro68k's source names and order. Fixed priority (one /INT line); IM 2 vector = VECBASE + 2 × source |
| 9 | Timers | retro68k's model at 16 bits: 4 timers, each CTRL, PRESCALE, RELOAD, COUNT, STAT, with retro68k's sources and chaining; a watchdog |
| 9 | Register map | retro68k's block order and names, narrowed to bytes. **System block** on 8-bit ports (A15–A8 ignored, so `OUT (n),A` and `OTIR` work), in retro68k's order: `0x00`–`0x0F` interrupts, `0x20`–`0x4F` timers and watchdog, `0x50`–`0x57` serial, `0x58`–`0x5F` SD, `0x60`–`0x6F` keyboard and joysticks, `0x70`–`0x7F` system, `0x80`–`0x9F` MMU read and write pages, `0xA0`–`0xBF` geometry unit (branch 10). Spectrum extras at `0x1F` (Kempston) and `0xFE` |
| 9 | Custom block | The chipset is retro68k's "custom block", 1 KB on **16-bit ports**: port = offset bits 7–0 in the high byte, `0xC0` + offset bits 9–8 in the low byte (`LD BC,reg` then `OUT (C),A`; `INC B` steps to the next register). Layout: `0x000` video globals and palette ports, `0x020` layer 0, `0x040` layer 1, `0x060` sprites 0–7 (16 bytes each), `0x0E0` copper control; `0x100` copper storage registers, `0x120` attribute layer, `0x140` DMA engine, `0x180` audio (reserved). The register page mirrors both blocks |
| 9 | Copper MOVE | One word: register (8 bits) and data (8 bits). Codes `0x00`–`0xEF` are MOVEs to custom offsets `0x000`–`0x0EF`; codes `0xF0`–`0xFF` are the other instructions, with a second word where needed. A two-word MOVEL reaches any custom register |
| 9 | Sprite order | DEPTH first, then number, as retro68k (replaces the earlier "number order") |
| 9 | Copper reads | No SRAM table reads: X and Y are 8-bit registers, as retro68k; per-cell colour is the attribute layer's job. A shared "MOVR from (X)+" stays an open point for both machines |
| 9 | Sprite limit | None, as retro68k: a guaranteed budget per line is stated; beyond it a late row sets SPRUNDER and the highest-numbered sprites lose first |
| 9 | Beam | Software sees the draw beam everywhere (BEAMPOS, LINECMP, VBLANK, copper waits), one line ahead of the screen |
| 9 | Spectrum extras | Kept, each in its own section outside the retro68k core: port `0xFE` (keyboard rows, border, beeper), Kempston `0x1F`, the attribute layer, NMI monitor paging |
| 10 | 3D target | **Flat-shaded polygons** (one colour each), as in Elite or Starglider 2 but at 25–50 frames a second. No Z-buffer (it would triple the memory traffic): software sorts back to front |
| 10 | 3D hardware | First a **geometry unit** (matrix multiplier). Help with drawing (span fill or a triangle job in the DMA engine) is decided later. retro-z80 only, not in retro68k: a Z80 has no multiply, so it sits in its own section like the Spectrum extras |
| 10 | Geometry: numbers | Coordinates signed 16-bit integers; matrix entries signed 2.14 fixed point; sums 32-bit inside, results 16-bit. A result that doesn't fit **saturates** to −32768 or +32767 and sets a status bit |
| 10 | Geometry: matrices | **Two** 3×3 matrices, each with a translation vector: camera and object. Writing the object matrix makes the unit multiply them (camera × object) itself. A vertex then gives X = m11·x + m12·y + m13·z + tx, and so on |
| 10 | Geometry: perspective | Selectable by a control bit: screen x = cx + d·X ÷ Z, y = cy − d·Y ÷ Z, with d, cx and cy set once. A vertex with Z below a set minimum sets a **NEAR** bit and comes back unprojected (X, Y, Z), so software can clip or drop it |
| 10 | Geometry: extras | Plain 16×16 → 32 signed multiply and 32 ÷ 16 divide, on the same DSP slices and divider |
| 10 | Geometry: access | Ports, and as memory through the register page (LDI, LD (IX+d)); writing z starts a vertex. About 150 T-states a vertex at 28 MHz against 2,000–3,000 in software. The unit finishes in under 1 µs, before the Z80 can read back, but a busy bit is kept |
| 10 | Geometry: when | Specified after the DMA engine spec, which leaves room in its job codes for a later drawing job |
| 11 | Memory timing | **retro68k's:** 100 MHz system clock, 20 ns memory cycles, 100 ns slots of 5 cycles. Display on cycles 1 and 3 (as retro68k); CPU on cycles 0 and 2; audio and the free pool (copper, DMA engine, cycles others leave) on cycle 4. Replaces the 56 MHz clock, the 4-cycle slots and the 28 MHz swap |
| 11 | CPU speed | Z80 top speed **20 MHz** (2 T-states per slot, locked to the slots). CPUSPEED is a divider n = 1–8, a T-state every 5n clocks: 20, 10, 6.67, 5, 4, 3.33, 2.86, 2.5 MHz, all slot-locked; plus a 3.57 MHz code (÷28) for Spectrum timing. 25 MHz to be tried in simulation (open point). Replaces branch 2's 28 MHz |
| 11 | Video design | **retro68k's design and RTL as built**: just-in-time layer fetch through its scheduler, data registers and shifters, mixing on the pixel side; software sees the display beam; 2×-tall layers fetch every line. The only new hardware is a **tile mode** in the layer fetcher. The FIFOs, draw beam, line buffer and repeat buffer go |
| 11 | Layers | **Three layers L0–L2**, chunky only (no planar), 1/2/4/8 bpp, scale 1×, 2×, 4× or 8× each way, PRIO, **direct colour**. Each a bitmap or a tile map |
| 11 | Colour | **24-bit** palette entries as retro68k (3 bytes: blue, green, red; red commits); BGCOLOR 3 bytes. PALETTE0–2 and SPRPALETTE. Default: the Spectrum colours in entries 0–15 at `0xD7` (normal) and `0xFF` (bright) |
| 11 | Sprites | retro68k's 8 sprites as built, streamed through its 32-word FIFOs (no image-row limit); **fractional scaling** with SPRxSTEP (XSTEP, YSTEP, 5.11, `0x0800` normal), as retro68k; signed HSTART. **No manual mode** (no SPRxDAT), so 16 bytes per sprite. Reuse needs one gap line |
| 11 | DMA engine | **retro68k's version 1** narrowed: 4 channels, descriptors in SRAM, COPY, FILL, KEYCOPY, LOGIC, ADD at 1–8 bpp, registers, palettes and the SD/serial ports as sources or destinations. No HIGH mode. OP 6–7 reserved, to agree with retro68k for the 3D drawing job. Sources DMA0–DMA3 |
| 11 | Ports | Every port is **register (high byte) : page (low byte)**. Page `0x00` the system block (register numbers as the old system ports); pages `0x10`–`0x13` the custom block; `0x1F` Kempston, `0xFE` Spectrum (high byte picks keyboard rows) and the stream ports SERDATA (`0x53`), SDDATA (`0x5B`), KBDATA (`0x62`) ignore the high byte. Writes `OUT (C),r`; reads `LD A,reg` then `IN A,(page)`; `OUT (n),A` is given up. Full I/O access is kept alongside the register page (the MMU must be reachable before the page is mapped) |
| 11 | Register page | Page p, register r at offset p × 256 + r: the port with its bytes swapped. Palettes memory-only at `0x1400`–`0x1FFF` (3 bytes an entry) plus PALIDX/PALDAT |
| 11 | Custom block | `0x000`–`0x00F` video globals; `0x010`–`0x08F` sprites 0–7; `0x090`, `0x0B0`, `0x0D0` layers L0–L2 (32 bytes each); `0x0F0`–`0x0FF` video read-only; from `0x100`: copper control and state, sprite globals, attribute layer, DMA engine (4 channels), audio (reserved). Copper MOVE reaches `0x000`–`0x0EF` |
| 11 | Small items | `CMOVEL` keeps retro68k's meaning (a whole wide register); the one-byte far move is `CMOVEF`. Unused addresses read `0xFF`. Serial: retro68k's control sequence; check RXCOUNT before reading. SDCON keeps retro68k's layout; no SD transmit buffer. SERDROP, a membrane key map and JOY1X/JOY2X get registers. PS/2 keys also show on `0xFE`. No IM 0, no hardware debugger (since replaced by branch 18's debug unit). CHIPMB is a build option. No UPLOAD on a long reset press; beeper level fixed. Copper prefetch 2 words; RESUME doesn't save the latch. The boot console belongs to spec 7. Deferred: 48-bit TIME, timer capture, DMA job queue, high-speed SD, accelerator-pin interrupts, a faster paging port |
| 11 | Next specs | 15 geometry unit (branch 10; its registers in the system page, reached by `OUT (C)` or the register page), 16 boot ROM |
| 11 | Review | Sprite HSTART unsigned, as retro68k's RTL. Port `0xFE` border writes act immediately (mid-line stripes; a Spectrum extra); BGCOLOR written as a register keeps retro68k's line-start rule. Byte names are digits everywhere (NAME0, NAME1 …; `MMU0_0` where the name ends in a digit). The DMA engine reads the boot ROM through its second block-RAM port; port jobs move bytes over the register bus, paced by the unit |
| 11 | Register writes | **Direct, no latches** (CPU, copper, DMA engine): every register byte is written straight through, in any order, with any instruction. Software changes wide display registers in the vertical blank or with the copper at a set position, as on the Amiga. Three exceptions: MMU pages commit on the high byte; palette entries change when the red byte arrives (the PALDAT assembly); reads of live counters capture on the low byte (one tagged capture per master, as retro68k). Replaces the per-register latches (saves about 1,000–2,000 LUTs) |
| 11 | Sprite restart | As retro68k's rewritten sprite spec: a **CTL write starts** a sprite (one byte, never half-written); **the vertical blank stops every sprite**, so each frame the copper or CPU writes the sprite's registers with CTL last. PT, H, V and STEP act on a running sprite from the next line; a PT write sets the next image line's start (its three bytes within one line, or while the sprite is stopped); the window is checked every line; HSTART is 16 or more; SPRDMA pauses a sprite. Replaces the DMA-off workaround (spec 5, S10) |
| 12 | First board | The **KS2** (issue 4) is the first hardware target, a bring-up build, while the KS3 is on its way. Same RTL with a board option (issue 4 / issue 5): the KS2 pin file from the Next's sources, 2 MB SRAM (CHIPMB), 9-bit VGA (HDMI keeps 24-bit), file `core2.bit` |
| 12 | KS2 contents | CPU, MMU, SRAM, boot ROM, serial, interrupts, timers, layers with palettes, copper. Sprites, the DMA engine and the attribute layer are added only while they fit the XC7A15T's 10,400 LUTs; the full machine waits for the KS3 |
| 12 | Loading | JTAG with the user's Xilinx Platform Cable USB (Vivado Hardware Manager). The FT232H module is still to get; until then KS2 output is on screen only |
| 12 | RTL reuse | retro68k's modules are **copied** into this repo at a recorded retro68k commit, each listed with its origin and what was changed in a provenance file next to the RTL; later retro68k fixes are ported by hand. Each unit's register interface is **narrowed** to retro-z80's byte registers exactly as the specs lay them out (no 32-bit adapter). Each ticket copies the modules it needs; copy only from a committed retro68k state |
| 13 | BASIC | **BBC BASIC (Z80) v5.00** by R. T. Russell (zlib licence; github.com/rtrussell/BBCZ80), the interpreter (16,374 bytes) unchanged apart from assembler syntax for sjasmplus, with Russell's ACORN.Z80 graphics and sound layer |
| 13 | BASIC: where | A **ROM image in write-protected SRAM**: the boot ROM loads it from SD or over serial into SRAM pages and sets their write page to NONE; a checksum lets a warm reset skip the reload. No extra block RAM |
| 13 | BASIC: host layer | A **new retro-z80 host layer** (OSINIT, OSWRCH, OSRDCH, OSLINE, OSKEY, OSCLI, files, TIME, VDU/PLOT and the rest): console on a tile layer, PS/2 and Spectrum keyboards, SD/FAT files, a 100 Hz tick from a timer; borrowing VDU, PLOT and line-editor code from Dean Belfield's Spectrum Next and Cerberus ports (zlib) |
| 13 | BASIC: name | The README says the name "BBC BASIC" is not transferable to a derived work: ask R. T. Russell for permission to call it "BBC BASIC (Z80) for retro-z80"; until then "retro-z80 BASIC, based on BBC BASIC (Z80) by R. T. Russell" |
| 13 | BASIC: when | After phase 1, with the boot ROM spec (16), the SD card, keyboard and console; research notes in `docs/notes/bbc-basic.md` |
| 14 | Sprite sequencer | A retro-z80 extra (retro68k keeps it on its "later" list and may copy it unchanged): an alternative to copper lists for reusing the 8 sprites down the screen. A small **register-bus master** reads a list in SRAM sorted by start line and writes each entry into the SPRx registers in the gap line after a sprite's previous use ends (H, V, STEP, PT, then CTL last), so the sprite hardware is unchanged and the copper can be mixed in. A few hundred LUTs |
| 14 | Sequencer: list | Each entry is a sprite's 16 register bytes as in the custom block (PT 3, H 4, V 4, CTL 1, STEP 4); its VSTART is the start line; software sorts by it; an entry with VSTART `0x7FF` ends the list. SEQLC (3 bytes) points at the list and is reloaded every frame, as COP1LC is |
| 14 | Sequencer: sprites | The hardware gives each entry the **lowest-numbered free sprite** among those allowed by **SEQMASK** (one bit per sprite; the rest stay with the copper and CPU). An entry whose start line comes with no sprite free is **skipped** for that frame: SEQSTAT.SKIP (sticky) and a count of skipped entries, with an optional interrupt through VIDERR |
| 14 | Sequencer: spec | New spec 17, written now; built in phase 4 after the sprite unit is copied from retro68k (main `bf91e97`). Registers in the custom block's MOVEF range |
| 15 | PC keyboard | **Now: a serial console**, as retro68k: the monitor, the boot console and BASIC's host layer read keys from the USB serial link as well as from the keyboards, so any PC terminal works. **Later: key injection** (a retro-z80 extra): control commands on the link carry PS/2 key-down and key-up codes into the keyboard unit, so they reach KBDATA and the Spectrum rows on port `0xFE` like a real keyboard's; with a small PC tool that sends presses and releases |
| 16 | Monitor | **Designed once with retro68k:** one shared spec, "Monitor and upload protocol", kept word for word the same in both repos (commands, syntax, upload protocol, file header, one PC upload tool in `tools/`), plus each machine's own boot ROM spec (spec 16 here) for the CPU parts. Draft written here, reviewed and adopted by retro68k |
| 16 | Monitor: commands | One letter and hex arguments (addresses up to 8 hex digits; `.B`/`.W`/`.L` access size, byte by default; sizes checked so a 68000 never faults): examine, enter, fill, copy, compare, go, registers, ports (Z80), disassemble, upload, boot from SD, help. On the screen and keyboard and the USB console at once |
| 16 | Monitor: disassembler | In the Z80 boot ROM; optional on retro68k |
| 16 | Upload and boot file | Binary frames with a length and a CRC; a header with machine ID, load address, entry point and a "new boot ROM image" flag; an "ok" or "CRC error" reply. The SD boot file (`BOOT.Z80` / `BOOT.68K`) uses the same header. No UPLOAD on a long reset press (both machines; retro68k's SY3 answered the same). ROMLOCK is decided at power-on only (D held leaves it clear) |
| 16 | Program environment (Z80) | The **boot ROM stays in window 0** (`0x0000`–`0x1FFF`) with RST entry points to its console routines (print, read key, and so on), like a Spectrum ROM; windows 1–7 are SRAM, so programs get 56 KB. Details in spec 16 |
| 17 | Interrupt pages | A retro-z80 extra (retro68k has no MMU): **the MMU switches chosen windows on an interrupt.** A mask picks the windows, each with an interrupt page; on the acknowledge the hardware saves those windows' pages and loads the interrupt pages, so a handler, its stack and data live in their own bank whatever the program has mapped |
| 17 | Interrupt pages: restore | The pages **switch at the acknowledge, before the pushes**, so the return address goes through the interrupt bank's map (into the interrupt bank if SP is in a switched window), and are **restored after RETI's or RETN's two pops**, before the fetch at the return address; or by writing a **restore** register (for handlers ending EI; RET). **Nesting:** only the first acknowledge switches; nested ones count up, each RETI or restore counts down, and the program's pages return when the count reaches 0 |
| 17 | Interrupt pages: NMI | The NMI uses the same mechanism with its own mask and pages (by default window 0 to the monitor ROM, as the NMI paging does now), restored at RETN: one design instead of two |
| 17 | Stack capture | **NMI only, always on** (not a bit software can clear): the NMI response's two stack writes (the return address) go into capture registers instead of memory, so a bad SP corrupts nothing, and RETN takes its two stack reads from the capture, so SP returns to the program's value and memory is never touched. The captured PC (writable, so the monitor's G can resume elsewhere) and the SP the pushes were aimed at are readable. **Maskable interrupts have no capture:** they use the interrupt pages, so their return address goes through the switched map |
| 17 | Interrupt pages: cost and NMI pushes | The page sets are kept in a small RAM (distributed RAM) and copied into the MMU one window per clock, rather than as flip-flops; fewer windows only if the copy does not fit in time. The NMI set's window 0 **write page is the monitor's workspace page**, so with capture on an NMI changes nothing in the program's memory |
| 18 | Remote debugging | **Debugging the real KS2 from VS Code** over the FT232H link (no emulator for now): load, run, pause, breakpoints, watchpoints, step, registers and memory, at asm source level from sjasmplus SLD files (C later) |
| 18 | Debugging: PC side | *Replaced by branch 20.* `tools/rdebug.py`, a **Python debug adapter** (DAP on stdio to VS Code, the debug protocol to the boot ROM), sharing the link code (frames, CRC-32, BREAK/RESET/UPLOAD) with `rlink.py`; a **small VS Code extension in this repo** registers the `retro-z80` debug type. Launch uploads the program and stops at its entry; attach sends BREAK |
| 18 | Debugging: link | While VS Code is attached, **the link carries only debug frames**; the program's console output goes to the screen only |
| 18 | Debugging: protocol | A new **shared spec `debug.md`**, CPU-neutral like `monitor.md` (a column per machine where they differ), using the upload frames. Z80 first; offered to retro68k to copy word for word, nothing waits for it |
| 18 | Debug unit | A retro-z80 extra in the FPGA: **single step** (an NMI after the next instruction), **4 instruction breakpoints** (compare on the M1 fetch), **2 watchpoints** (address and mask; read, write or both; memory or I/O). All raise the NMI. A breakpoint matches the 16-bit address and **optionally the page** in that window. Maskable interrupts are **held off during a step** unless the debugger asks to step into handlers |
| 18 | Debugging: breakpoints | **Hardware only** (so they work in ROM); a fifth is refused (unverified in VS Code). The monitor uses the unit too: `G addr break` sets a hardware breakpoint, and a new step command (letter to agree with retro68k in the shared monitor spec) |
| 18 | Debug stub | In the boot ROM's NMI handler, on **branch 17's NMI part** (NMI wired, the window switch to the workspace page, stack capture), so it never touches the program's memory or stack. That NMI part is built first; the maskable interrupt pages later |
| 18 | Debugging: views | Registers (with alternates, I, R, IM, IFF), the 8 MMU windows (read and write pages), memory, disassembly, a call stack from return addresses on the stack that SLD knows, breakpoints and watchpoints, and a debug console for monitor-style commands |
| 18 | Screen capture (future) | **Not built yet.** A unit taps the final pixel (after layers, sprites, copper, palettes and border, as HDMI/VGA get it), keeps a slice of each line in a small block RAM buffer, and sends it on the FT232H during the rest of the line, a further slice each frame: about 84 pixels a line in 24-bit colour at 8 MB/s, so a whole picture in about 8 frames (0.13 s), exact while the program is stopped, a slow-scan live view while it runs. No CPU involvement. Its packets are a frame type of the debug protocol; VS Code shows the picture in a panel. Synchronous FIFO mode (serial U5) would make it near live. It also lets the board's real output be compared pixel by pixel with the video model the simulation tests use (retro68k: vmodel.py). Replaces rebuilding the picture from memory |
| 19 | Sprites on the KS2 | Built **on the KS2 now**: retro68k's `sprites.v` and `sprite_pix.v` **copied from its main and narrowed** to spec 5 (byte registers, 16 bytes per sprite at `0x010`, no manual mode, a sprite never takes the CPU's cycle). **SPRPALETTE is built** (SHAREPAL works too). A build parameter **NSPRITES** (8; fewer on the KS2 only if 8 do not fit; a missing sprite's registers read `0xFF`) |
| 19 | Sprites: tests and demo | retro68k's `spr` video screen against the Python model: a **short run locally, the full screen in CI**. KS2 demo: **8 sprites** (2/4/8 bpp, sizes, DEPTH behind and in front of L0, SPRxSTEP zooms) bouncing over the tile scroller, the border flashing on SPRCOLL; images drawn into SRAM by code; started by a key at the monitor. With no copper yet, the **CPU's VBLANK handler** writes each sprite's registers, CTL last |
| 19 | Order | Sprites, then **the copper** (spec 6, retro68k's narrowed; the demo moves to it), then the sprite sequencer (spec 17) |
| 20 | PC side: one bridge | **One Python process, `tools/rz80_bridge.py`, owns the serial port** and serves DAP on TCP and MCP on HTTP at once, as the ZX Spectrum emulator's `zx_server` does. VS Code and an MCP client (Claude) share the board and see the same stops. Replaces branch 18's stdio adapter. Standard library and `pyserial` only, DAP and MCP written by hand; the link code is `rlink.py`'s. The zx emulator's behaviour is copied, not its code |
| 20 | Bridge: attach | The bridge opens the port but **leaves the board running**. A VS Code launch or attach, or MCP's `launch` or `attach`, stops it; detach lets it run on. No tool attaches by itself |
| 20 | Bridge: console | The monitor console goes through the bridge: a **VS Code terminal panel** and **MCP console tools** (`send_console`, `read_console`), while not attached |
| 20 | Bridge: breakpoints | VS Code and MCP share **one pool**: 4 breakpoints and 2 watchpoints, first come, first served, each listed with who set it; a fifth is refused (unverified in VS Code, an error in MCP) |
| 20 | MCP tools | **zx_server's names and arguments where they mean the same** (`get_registers`, `set_registers`, `read_memory`, `write_memory`, `set_breakpoint`, `clear_breakpoint`, `list_breakpoints`, `set_watchpoint`, `clear_watchpoint`, `list_watchpoints`, `step`, `run`, `pause`, `load_debug_info`, `resolve_symbol`, `resolve_address`, `server_info`, `get_state`), plus retro-z80's own: `launch`, `attach`, `detach`, `reset`, `get_mmu`, `monitor`, `send_console`, `read_console`. No screen tools until screen capture exists |
| 20 | VS Code extension | **Its own extension in this repo** (`tools/vscode/`, debug type `retro-z80`), a **full copy** of the zx extension's patterns so it stands alone: the bridge started if nothing listens and joined if something does, the server adverts, the z80-asm language with the asm index (go to definition, hover) and the sjasmplus finder. Copied files recorded in `tools/vscode/PROVENANCE.md` |
| 20 | Extension: first scope | Beyond the debugger: the **program panel** (a `.rimg`'s header, Run and Debug buttons) and the **watchpoint panel** (the 2 hardware watchpoints and who set them). Not yet: graphics viewer, screen, profiler, tape tools |
| 20 | Build | **preLaunchTask, as zx**: a task type the extension adds runs sjasmplus (`--sld`) and makes the `.rimg` with `rlink.py`; launch only uploads |
| 20 | Before the FT232H | Developed and tested against the **Python model of the stub** (debug.md's test plan): the bridge, DAP and MCP need no hardware. The Verilator run of the real stub stays in debug.md's test plan |

## 2. Key decisions

> Branch 9 of section 1 (23 October 2026) brought the chipset back in line with retro68k, and branch 11 took retro68k's memory timing and video design too. D2–D11 follow both. Each spec has a "Comparison with retro68k" section. Each spec has a "Comparison with retro68k" section listing every difference and its reason.

### D1. Board: ZX Spectrum Next KS3

Same as retro68k (its design plan, D1): Artix-7 XC7A35T, 4 MB (or 2 MB) of 10 ns SRAM, HDMI and an ADV7125 VGA DAC, audio jack, SD card in SPI mode, PS/2 sockets, two joystick ports, the Spectrum membrane keyboard, the accelerator port for the FT232H module, and a 50 MHz oscillator. Vivado free edition, scripted in Tcl, loaded over JTAG during development, installed as a Next core when finished.

### D1a. First board: KS2 (issue 4)

Checked against the Next's FPGA sources (`zxnext_top_issue4.vhd`, `zxnext_pins_issue4.xdc`, `nextreg.txt`, the issue 4 schematic) on 23 October 2026:

| | KS2 (issue 4) | KS3 (issue 5) |
|---|---|---|
| FPGA | XC7A15T-1CSG324: 10,400 LUTs, 20,800 flip-flops, 50 × 18 Kb block RAM, 45 DSP | XC7A35T-2CSG324: 20,800 LUTs, 100 block RAM, 90 DSP |
| SRAM | IS61WV102416FBLL-8: 2 MB, 16-bit, 8 ns | IS61WV204816BLL-10: 4 MB, 16-bit, 10 ns |
| VGA | 3 bits per colour, resistor ladder | ADV7125, 8 bits per colour |
| Same on both | 50 MHz oscillator, HDMI from the FPGA, accelerator header (FT232H), 14-pin JTAG header, SD (SPI), PS/2, joysticks, membrane keyboard, Vivado | |
| Cores | Slots 2,176 KB apart; file `core2.bit` | Same spacing; `core3.bit` |

The KS2's slower speed grade makes 100 MHz harder to meet; a smaller design helps, and the first Vivado build will tell (open question Q11).

### D2. CPU: tv80

- **tv80**, a Verilog version of the T80 core (MIT licence), so the whole design stays in Verilog and runs in Icarus and Verilator like retro68k. Checked with the ZEXDOC and ZEXALL instruction tests (open question Q3).
- The core runs on the 100 MHz system clock with a clock enable and multicycle constraints (spec 1). **CPUSPEED** is a divider n = 1–8, a T-state every 5n clocks: **20**, 10, 6.67, 5, 4, 3.33, 2.86 or 2.5 MHz, all locked to the memory slots; plus a SPECTRUM code, 3.57 MHz (÷28). Reset gives 20 MHz. 25 MHz would need the old "swap" back (spec 1, open point B10).
- **Interrupts:** IM 2, with the controller giving VECBASE + 2 × source during the acknowledge; IM 1 reads INTID. NMI from the Multiface button and a USB "break".

### D3. Clocks

As retro68k (its D4):
- **System clock 100 MHz** from MMCM 1 (50 MHz × 20 = VCO 1000 MHz, ÷ 10). CPU speeds are clock enables.
- **Pixel clock 27 MHz** (and 135 MHz for HDMI) from MMCM 2, treated as asynchronous.
- Every 576p line (32 µs) is exactly **3200 system clocks = 320 memory slots**.

### D4. Memory: slots and the MMU

Defined in [spec 2: memory](spec/memory.md). retro68k's memory system (its spec 5):

- **Slots.** A memory cycle is 2 system clocks (20 ns) and moves 16 bits; a slot is 5 cycles, 100 ns; 100 MB/s in total.

  | Cycle | Owner |
  |-------|-------|
  | 0 | CPU |
  | 1 | Display (layers, sprites, attribute layer), earliest deadline first |
  | 2 | CPU |
  | 3 | Display |
  | 4 | Audio (reserved); free pool |

  A cycle its owner does not use goes to the free pool: hard-deadline display channels first, then audio, the copper and the DMA engine. A cycle the CPU asked for is never taken, so **the Z80 never waits**; it uses at most one of cycles 0 and 2 in a slot.
- **MMU.** Eight 8 KB windows, each with a **read page** (registers `0x80`–`0x8F` of the system page) and a **write page** (`0x90`–`0x9F`). Setting the read page also sets the write page; setting the write page afterwards splits the window. 10-bit page numbers: `0x000`–`0x1FF` SRAM (on a 2 MB board the top half mirrors the bottom), `0x3F8` the register page, `0x3FB` NONE, `0x3FC`–`0x3FF` the 32 KB boot ROM. Reset: windows 0–1 = ROM, 2–7 = SRAM pages 0–5.
- The chipset uses 22-bit physical SRAM addresses, not the MMU.

### D5. Video

Defined in [spec 4: video](spec/video.md). **retro68k's video as built**, narrowed to 8-bit registers:

- 576p (720×576 at 50 Hz) over HDMI and VGA, retro68k's platform modules and beam coordinates.
- **Three layers L0–L2**, chunky 1/2/4/8 bpp, each a bitmap or a **tile map** (the one new piece of hardware: 8×8 tiles, MAPPT, PATPT, maps of 32/64/128 entries each way, entries with tile, palette block, flips and PRI). HSCALE and VSCALE 1×, 2×, 4× or 8×; windows, BPLSTRIDE, SCROLLX/SCROLLY, WRAP; PRIO; direct colour.
- Fetched just in time through the scheduler into data registers and shifters, mixed on the pixel side; software sees the display beam. Budget: 1.48 bytes per pixel.
- **24-bit palettes** PALETTE0–2 and SPRPALETTE (256 entries, 3 bytes each), PALOFS, SHAREPAL; BGCOLOR 3 bytes. Default palette: the Spectrum colours in entries 0–15.
- Interrupts VBLANK, LINE, VIDERR.
- **Spectrum extras:** the attribute layer, port `0xFE` border colours, the Spectrum screen layout by the copper.

### D6. Sprites

Defined in [spec 5: sprites](spec/sprites.md). **retro68k's 8 sprites as built:** SPRxPT, SPRxH, SPRxV, SPRxCTL (one byte: BPP, DEPTH, PAL), SPRxSTEP (fractional scaling, 5.11); 16 bytes each; a 32-word FIFO per sprite, streamed through the scheduler; SPRDMA, SPRCOLL, SPRUNDER. No manual mode. DEPTH first, then number.

### D7. Copper

Defined in [spec 6: copper](spec/copper.md). retro68k's copper in 16-bit words with 8-bit data: MOVE (one word) to custom offsets `0x000`–`0x0EF`, MOVEF (two words) to any offset; WAIT, SKIP, JUMP, STOP, MOVR, the ALU, SKIPC, CALL/RET; COPCON (with PRI), COP1LC, COP2LC, COPJMP1/2. Macros as retro68k (`CMOVEL` writes a whole 4-byte register). Reads its list from the free pool; follows the display beam.

### D8. Registers

Defined in [spec 3: register map](spec/registers.md).

- Every I/O port is **register (high byte) : page (low byte)**. Page `0x00` is the system block, pages `0x10`–`0x13` the 1 KB custom block. Writes `LD BC,port` then `OUT (C),r`; reads `LD A,reg` then `IN A,(page)`. Ports `0x1F`, `0xFE` and the stream ports SERDATA, SDDATA, KBDATA ignore the high byte, so `INIR`/`OTIR` work on them.
- The **register page** (MMU page `0x3F8`) holds page p, register r at offset p × 256 + r, the keyboard rows at `0x0100`, and the palettes at `0x1400`–`0x1FFF`.
- Registers are bytes; wider values sit low byte first and commit on the highest. The copper has its own latch. Sources: `fpga/regmap.def` → `tools/regmap.py` → headers.

### D9. I/O and interrupts

| Block | Spec | In short |
|-------|------|----------|
| Interrupts | [8](spec/interrupts.md) | retro68k's controller; fixed priority; IM 2 vector = VECBASE + 2n; IM 1 reads INTID |
| Timers | [9](spec/timers.md) | 4 × 16-bit timers, a 32-bit µs TIME counter, a watchdog |
| DMA engine | [14](spec/dma-engine.md) | retro68k's version 1: 4 channels, descriptors, COPY, FILL, KEYCOPY, LOGIC, ADD at 1–8 bpp |
| USB serial | [10](spec/serial.md) | FT232H, retro68k's registers and control commands; SERDROP |
| SD card | [11](spec/sd-card.md) | SPI byte master, polled; a DMA port |
| Input | [12](spec/input.md) | PS/2 keyboard; joysticks with six-button pads; membrane key map; Spectrum extras: port `0xFE` (also fed by PS/2 keys), Kempston `0x1F` |
| System | [7](spec/system.md) | SYSID, SYSVER, SYSCFG, RESETWHY, SYSCON, SYSRESET, SYSBTN, CPUSPEED, I2C; the boot console; NMI monitor paging (Spectrum extra) |

### D10. Software and tools

- **HDL:** plain Verilog-2005; chip-specific parts in `fpga/rtl/platform/artix7/` with behavioural copies for simulation.
- **CPU wrapper:** `fpga/rtl/z80_cpu.v` around tv80, bringing out the clock enable and the core's early cycle signals (spec 1).
- **Simulation:** Icarus Verilog for blocks, Verilator for the whole computer (fast enough to run ZEXDOC).
- **Z80 code:** sjasmplus; z88dk if C is wanted later.
- **Boot ROM:** a monitor (dump, edit, load over USB or SD, run), then **BBC BASIC (Z80)** by R. T. Russell (open source, zlib licence). **CP/M 3** later.
- **Shared with retro68k:** the KS3 pin list, MMCM, HDMI and VGA modules, TMDS encoder, the FT232H serial logic, the SRAM and FT232H simulation models, and the register-map generator. They are copied in, since the bus widths differ.

### D11. Block RAM budget

| Item | Blocks (18 Kb) | Spec |
|------|----------------|------|
| Boot ROM, 32 KB | 16 | 7 |
| Palettes (4 × 256 × 24 bits, kept twice as retro68k) | 4 | 4 |
| Video and sprites otherwise | As retro68k's build, to be measured | 4, 5 |
| USB serial FIFOs | 2 | 10 |
| PS/2 keyboard FIFO | 1 | 12 |
| DMA descriptor RAM (open point) | 1 | 14 |

retro68k's whole design uses 12.5 of 50 (36 Kb) blocks, so both boards have room. Logic is to be measured: retro68k is 12,771 LUTs on the KS3 with fx68k; tv80 is of similar size. The KS2 build carries only part of the machine (branch 12).

## 3. I/O port map

The full list is in [spec 3](spec/registers.md). Ports are register (high byte) : page (low byte).

| Page | Registers | Block |
|------|-----------|-------|
| `0x00` | `0x00`–`0x0F` | Interrupt controller |
| `0x00` | `0x10`–`0x16` | Membrane key map |
| `0x00` | `0x1F` | Kempston (also any port with low byte `0x1F`) |
| `0x00` | `0x20`–`0x4F` | Timers, TIME, watchdog |
| `0x00` | `0x50`–`0x57`, `0x5C` | USB serial (SERDATA `0x53` also any high byte), SERDROP |
| `0x00` | `0x58`–`0x5F` | SD card (SDDATA `0x5B` also any high byte) |
| `0x00` | `0x60`–`0x6F` | Keyboard, joysticks (KBDATA `0x62` also any high byte) |
| `0x00` | `0x70`–`0x7B` | System, I2C (`0x7C`–`0x7F` free: the NMI registers moved to page `0x01`) |
| `0x00` | `0x80`–`0x9F` | MMU read and write pages |
| `0x00` | `0xA0`–`0xBF` | Geometry unit (branch 10) |
| `0x00` | `0xFE` | Spectrum keyboard rows, border, beeper (low byte `0xFE`, high byte picks rows) |
| `0x01` | `0x40`–`0xFF` | Interrupt pages and the NMI's stack capture (branch 17); `0x00`–`0x3F` reserved |
| `0x02` | `0x00`–`0x3C` | Debug unit (branch 18): DBGCTL, DBGSTAT, the watched access, 4 breakpoints, 2 watchpoints |
| `0x10`–`0x13` | all | Custom block (below) |
| Others | | Reserved, read `0xFF` |

| Custom offset | Block | Copper |
|---------------|-------|--------|
| `0x000`–`0x00F` | Video globals, palette ports, DMACON | MOVE |
| `0x010`–`0x08F` | Sprites 0–7 | MOVE |
| `0x090`, `0x0B0`, `0x0D0` | Layers L0, L1, L2 | MOVE |
| `0x0F0`–`0x0FF` | Video read-only | – |
| `0x100`–`0x11F` | Copper | MOVEF |
| `0x120`–`0x12F` | Sprite globals | MOVEF |
| `0x130`–`0x13F` | Attribute layer (Spectrum extra) | MOVEF |
| `0x140`–`0x23F` | DMA engine, 4 channels | MOVEF |
| `0x240`–`0x2FF` | Audio (reserved) | MOVEF |
| `0x300`–`0x30F` | Sprite sequencer (branch 14) | MOVEF |

## 4. Specs

| # | Spec | Status |
|---|------|--------|
| 1 | [CPU bus interface](spec/bus-interface.md) | Draft |
| 2 | [Memory](spec/memory.md) | Draft |
| 3 | [Register map](spec/registers.md) | Draft |
| 4 | [Video](spec/video.md) | Draft |
| 5 | [Sprites](spec/sprites.md) | Draft |
| 6 | [Copper](spec/copper.md) | Draft |
| 7 | [System](spec/system.md) | Draft |
| 8 | [Interrupts](spec/interrupts.md) | Draft |
| 9 | [Timers](spec/timers.md) | Draft |
| 10 | [USB serial](spec/serial.md) | Draft |
| 11 | [SD card](spec/sd-card.md) | Draft |
| 12 | [Input](spec/input.md) | Draft |
| 13 | Sound | Waiting for Q1 |
| 14 | [DMA engine](spec/dma-engine.md) | Draft |
| 15 | Geometry unit (3D) | Next to write (branch 10) |
| 16 | [Boot ROM](spec/boot-rom.md) | Draft (branch 16): ROM pages, start-up, the program environment, the RST calls, the Z80 parts of the monitor and loader, BASIC as a resident image |
| – | [Monitor and upload protocol](spec/monitor.md) (shared with retro68k) | Draft (branch 16), word for word the same in both repos; for retro68k to review and adopt |
| 17 | [Sprite sequencer](spec/sprite-sequencer.md) | Draft (branch 14) |
| 18 | [Debug unit](spec/debug-unit.md) | Draft (branch 18): single step, 4 breakpoints with an optional page match, 2 watchpoints, all on the NMI; I/O page `0x02` |
| – | [Remote debugging protocol](spec/debug.md) | Draft (branch 18): its transport section (frames with a channel byte) offered to retro68k word for word; the debug channel is retro-z80's, for the bridge `tools/rz80_bridge.py` (VS Code and MCP, branch 20) |

## 5. Phases

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document and specs 1–12 and 14 agreed | Specs reviewed |
| **1. Simulated CPU** | tv80, bus interface, MMU, SRAM controller, boot ROM, USB serial, in simulation | Boot ROM prints "hello" over simulated serial; ZEXDOC passes in Verilator |
| **2. Video** | L0 in tile mode with the boot console, then bitmaps, palettes, PRIO, the attribute layer | Console text on the simulated screen, checked pixel by pixel |
| **3. On the board** | Bring-up build for the KS2 (branch 12), loaded over JTAG; then the full build for the KS3; boot monitor | KS2: the boot ROM's console on a real monitor and a RAM test at 20 MHz. KS3: the same plus "hello" over USB |
| **4. Games machine** | Copper, sprites, DMA engine, joysticks | A demo with scrolling tiles, magnified sprites reused down the screen and a Spectrum-style screen drawn by the copper |
| **5. Home computer** | SD card, keyboards, BBC BASIC | Boot to BASIC, load and save a program |
| **6. Next core** | Package and install as a Next core | The KS3 boots retro-z80 from its core menu |
| **Later** | Sound (if not before), geometry unit, CP/M 3; the 6502 machine (its own repo, branch 8) | |

## 6. Open questions

Each spec has its own open points; these are the ones that matter for the whole machine.

| # | Item | Plan |
|---|------|------|
| Q1 | Sound hardware: retro68k's 4 sample channels, AY-style chip(s), or both | Parked; custom offsets `0x180`–`0x1FF` and source AUDIO (9) reserved under retro68k's names; retro68k's audio narrowed would be the default |
| Q2 | 6502 version: build option here or its own repo | Closed: its own repo (branch 8). The chipset stays CPU-independent. A 6502 sees the registers through memory only (it has no I/O space); the CPU's two cycles per slot would serve it at 20 MHz with no waits |
| Q3 | Is tv80 exact enough (flags, undocumented instructions, interrupts)? | ZEXDOC and ZEXALL in Verilator in phase 1; fallback T80 (VHDL) |
| Q4 | Does the path from tv80's cycle signals through the MMU to the SRAM pads meet 100 MHz (multicycle)? | On the KS2 (issue #11): yes, even single-cycle (+0.89 ns from tv80's IR to the bus interface's address register), with tv80's own paths as 5-clock multicycle paths. Check again on the KS3 build (spec 1, B1); fallback: start a read speculatively in every T1 |
| Q5 | Copper priority | Closed: urgent display fetches come first in cycle 3, then the copper, then sprites (spec 2) |
| Q6 | Kempston port | Closed: port `0x1F` reads joystick 1 (spec 12) |
| Q7 | KS3 pins for the Spectrum keyboard, joysticks, PS/2 and `sd_miso`, not yet checked against the Next's pin file | Keyboard, joysticks and PS/2 checked (issue #19; spec 12, K2 and J1): the same pins on issue 4 and 5 except PS/2 (K1/L4 against N5/N6); keyboard rows open drain. `sd_miso` still to check (spec 7, SY1) |
| Q8 | The KS3 details still open in retro68k (SRAM size, accelerator pins, Next core format) | Answered once for both projects |
| Q9 | A Z80 faster than 20 MHz | Left for later. 25 MHz needs the swap back (spec 1, B10). Beyond that, the CPU would have to wait for SRAM, or run from block-RAM fast RAM only it uses; its limit is then tv80's own speed in the FPGA (Q3, Q4) |
| Q10 | Hardware help for 3D filled polygons | Partly answered by branch 10: a geometry unit (matrices, perspective, multiply and divide) comes first. Still open: drawing help, either (a) a span filler, (y, x0, x1, colour) filled in spare memory cycles, about 0.5k LUTs, with the Z80 stepping the edges, or (b) a triangle job in the DMA engine taking three screen vertices, about 1–2k LUTs. With fast vertices, edge stepping becomes the Z80's main cost, so (b) looks the better value. Double buffering already works by switching the layer pointer at vertical blank |
| Q11 | Does the KS2's XC7A15T-1 meet 100 MHz with the bring-up build? | Yes for the first computer build (issue #11: CPU, MMU, SRAM, boot ROM, serial, beam and background colour; 1,949 LUTs): worst slack +0.86 ns, with tv80's paths as 5-clock multicycle paths (`fpga/ks2/README.md`). To be checked again as layers, palettes and the copper are added; fallbacks: trim the design, or relax the slowest paths |

## 7. Next step

Review the specs, starting with the open points above. Then start phase 1 in simulation: the tv80 wrapper, bus interface, MMU, SRAM controller, boot ROM and USB serial.
