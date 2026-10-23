# BBC BASIC (Z80) on retro-z80: research notes

Date: 2026-10-23. Sources read: the BBCZ80 repository (cloned at commit `410e7fb`, 16 March 2025), Dean Belfield's Next, Cerberus and Agon ports, and the PainfulDiodes z88dk fork. All of them were cloned and read, not just skimmed. Sizes come from assembling the modules with sjasmplus 1.24.0 (`C:/tools/sjasmplus`). **[unconfirmed]** marks a claim that is not backed by a primary source.

## 1. The source

| Item | Finding | Source |
|------|---------|--------|
| Repository | github.com/rtrussell/BBCZ80, "BBC BASIC (Z80) v5". Last commit 16 March 2025 | https://github.com/rtrussell/BBCZ80 |
| Licence | **zlib**, "Copyright (c) 2024, Richard T. Russell" (`licence.txt`). It allows changes, which must be marked as such | https://github.com/rtrussell/BBCZ80/blob/master/licence.txt |
| Name | "The name 'BBC BASIC' is used by permission of the British Broadcasting Corporation and is not transferrable to a derived or forked work." The same text is in every core file header | README, MAIN.Z80 header |
| Earlier release | v3.00 (1987) was released under zlib in 2019 through David Given's cpmish. The Next, Cerberus and Agon (v3) ports are built on it | https://www.osnews.com/story/130145/r-t-russells-z80-bbc-basic-is-now-open-source/ ; next-bbc-basic README |
| Version | 5.00 (January 2025, WHATSNEW.TXT). Module headers go up to 5.3 (EVAL, 16-03-2025). Adds BASIC V features: WHILE, CASE, multi-line IF, whole arrays, `<<`/`>>`, byte variables, EXIT, `^`, and hooks for CIRCLE, ELLIPSE, FILL, LINE, ORIGIN, RECTANGLE, MOUSE, SYS, TINT, WAIT | https://github.com/rtrussell/BBCZ80/blob/master/WHATSNEW.TXT |
| Editions | Generic CP/M (CP/M 2.2 and 3, "plain vanilla"), and the Acorn Z80 Second Processor | README; CMOS.Z80, ACORN.Z80 headers |
| Downloads | bbcbasic.co.uk has generic CP/M (BBCZ80V5.zip, "no sound or graphics support"), Amstrad CPC, Tatung Einstein and Torch builds. "The interpreter uses about 16 Kbytes"; user memory is up to about 48 KB | https://www.bbcbasic.co.uk/bbcbasic/z80basic.html |

### 1.1 Files (`src/`)

| File | Role | Bytes assembled (sjasmplus) |
|------|------|------------------|
| MAIN.Z80 | Commands, line editor glue, errors, cold start (`START: JP COLD`, jump table) | 3,582 |
| EXEC.Z80 | Statements | 4,978 |
| EVAL.Z80 | Expressions, functions | 3,365 |
| ASMB.Z80 | Inline Z80 assembler | 1,383 |
| MATH.Z80 | Floating point (40-bit: 32-bit mantissa, 8-bit exponent) | 3,066 |
| **Core total** | "fits (just!) in 16 Kbytes so could be held in a ROM" (README) | **16,374** (10 bytes spare in 16 KB) |
| DATA.Z80 | RAM: ACCS (256), BUFFER (256), STAVAR, DYNVAR, PAGE, LOMEM, FREE, HIMEM, ERR... | 768 (DEFS only) |
| HOOK.Z80 | Stubs: every graphics, sound and other hook gives the error "Sorry" | 10 |
| CMOS.Z80 | CP/M MOS: files through BDOS FCBs, OSLINE editor, *commands, ESCAPE, SPOOL/EXEC | 2,160 |
| DIST.Z80 | CP/M patch at 0x100, at most 256 bytes: jump table CLRSCN, PUTCSR, GETCSR, PUTIME, GETIME, GETKEY, BYE, plus a configuration block at 0x1F0 (width, editing keys) | ≤ 256 |
| ACORN.Z80 | Acorn hooks: graphics and sound as VDU codes, OSWORD and OSBYTE calls to `&FFEE`, `&FFF1`, `&FFF4` | 1,010 |
| AMOS.Z80 | Acorn Tube MOS layer (still uses CP/M BDOS for files) | 1,588 |

The CP/M build (`bin/cpm/MAKE.SUB`) links `dist,main,exec,eval,asmb,math,hook,cmos` from 0x0100, with `/p:4B00,data`. The binary is 18,944 bytes. In my per-module assembly, the modules end at 0x4A70, which matches. The Acorn build puts DATA at 0x4C00.

### 1.2 Assembler and sjasmplus

- The original format is Microsoft/SLR style relocatable source: `TITLE`, `GLOBAL`, `EXTRN`, `ASEG`, `DEFB/DEFW/DEFM/DEFS`, `IF $ GT 1F0H`, `ERROR`. Each module is assembled with `z80asm x/rmf` and linked with `link` (MAKE.SUB).
- **sjasmplus (tested here).** Each module assembles once `TITLE`, `GLOBAL` and `EXTRN` are removed (EXTRN names set to dummy EQUs). Two more changes are needed:
  - The labels `PAIR` (MAIN, ASMB) and `ABS` (EVAL, MATH) clash with sjasmplus keywords, so they must be renamed.
  - EVAL's `AND`, `OR` and `MOD` EQUs give "operator keyword" warnings only.
  - `DIST`'s `'G' AND 1FH` and `IF $ GT` need checking.
- sjasmplus has **no linker**. A single-file build needs one of two things:
  - each file wrapped in `MODULE` with its globals prefixed `@` (Dean Belfield's method, next-bbc-basic README), or
  - every duplicate label renamed. There are about 100 clashes between modules, for example `CR`, `CMDTAB`, the `ERRORn` labels and the token EQUs.
- **z88dk-z80asm** builds it modularly, with `GLOBAL`→`PUBLIC`, `EXTRN`→`EXTERN` and sections. PainfulDiodes' `convert.sh` does this, and its CP/M output is **byte-identical** to the official `BBCBASIC.COM`; I checked with `cmp`. https://github.com/PainfulDiodes/BBCZ80 (building-BBCZ80.md)
- Sources: https://github.com/breakintoprogram/next-bbc-basic (README: "written to be assembled by the SJASMPLUS assembler", MODULE and `@` changes); https://github.com/hirosuzuki/BBCZ80-pasmo (a pasmo conversion, not read).

### 1.3 Memory, ORG, ROM-ability

- **Position.** The core has no fixed address of its own; the linker places it. Entry is the start of MAIN: `START: JP COLD / JP WARM / JP ESCAPE / JP EXTERR / ...` (MAIN.Z80).
- **Page alignment.** DATA's ACCS, BUFFER and STAVAR "must be on page boundaries" (DATA.Z80). The Next port also aligns USER/PAGE to 256 ("USER now aligned to page boundary – fixes bug in OLD", next-bbc-basic build.z80).
- **Cold start.**
  - `COLD` sets SP to STAVAR and clears it.
  - It calls `OSINIT`, which returns DE = HIMEM and HL = PAGE, plus NZ for auto-run. CP/M gives HIMEM = `(6)` rounded to a page, and PAGE = USER (end of DATA).
  - The stack sits just below HIMEM (`LD SP,(HIMEM)`). Programs, variables and the heap go from PAGE upwards. It is all one flat 16-bit space, with no banking in the core.
- **ROM.** All direct writes in MAIN, EXEC, EVAL, ASMB and MATH go to DATA symbols; I checked every `LD (label),` and found nothing in code. There is no self-modifying code. Tables are read-only. A `DEFB 21H` / `0F6H` trick skips the next instruction (one opcode swallowing the next), which is safe in ROM. So the **core can run from ROM** or a write-protected window. **CMOS is not ROM-safe as written:** it keeps writable variables inside its code (`TRPCNT: DEFB 10`, `TABLE`, `FLAGS`, `INKEY`, `EDPTR`, `OPTVAL`), and these would have to move to RAM.
- **Absolute addresses.** None in the core: no RST, IM, EI or DI. The exceptions are `LD A,R` (RANDOMISE), `OUT (C),L` (`PUT port,data`, a 16-bit port in BC) and an IN for `GET(port)`. These match retro-z80's `OUT (C),r` ports. CP/M addresses (5, 6, 5CH, 80H, RST 0) are used only in CMOS and DIST. ACORN assumes `&FFEE`, `&FFF1` and `&FFF4` entry points, and intercepts `CALL &FFxx` (OSCALL).

## 2. Host interface a port must supply

Found by listing every EXTRN in the five core modules that they do not define themselves. (A subroutine that is not exported is not listed.)

| Group | Routines (register conventions are in CMOS.Z80 comments) |
|-------|-----------------|
| Start/exit | `OSINIT` (returns HIMEM and PAGE, auto-run), `BYE` (*BYE, QUIT), `RESET`, `PROMPT` (prints `>`) |
| Character I/O | `OSWRCH` (A out, saves all registers), `OSRDCH`, `OSLINE` (line input and edit into a 256-byte buffer, CR-terminated), `OSKEY` (key with a time limit in centiseconds; INKEY and GET) |
| Escape | `TRAP` (called often; checks the escape flag and polls the keyboard every 20th call), `LTRAP` (flag only). Escape aborts through the core's `ESCAPE` |
| *commands | `OSCLI` (all `*` text), `OSCALL` (`CALL`/`USR` to `&FFxx`; CMOS just returns) |
| Files | `OSLOAD`, `OSSAVE`, `OSOPEN` (carry = OPENIN or OPENOUT), `OSSHUT`, `OSBGET`, `OSBPUT`, `OSSTAT` (EOF), `GETEXT`, `GETPTR`, `PUTPTR` |
| Screen and time | `CLRSCN`, `PUTCSR`, `GETCSR` (POS, VPOS), `GETIME`, `PUTIME` (TIME, centiseconds, 32-bit), `GETIMS`, `PUTIMS` (TIME$) |
| Graphics, sound and v5 hooks | `CLG COLOUR DRAW ENVEL GCOL MODE MOVE PLOT SOUND ADVAL POINT CIRCLE ELLIPS FILL MOUSE ORIGIN RECTAN LINE TINT TINTFN WAIT SYS CSRON CSROFF MODEFN WIDFN` (HOOK.Z80 makes them all "Sorry"; ACORN.Z80 implements them) |
| RAM | DATA.Z80 symbols: `ACCS BUFFER STAVAR DYNVAR PAGE LOMEM FREE HIMEM ERR ERL ERRTRP ...` |

Errors come back to the host only as code paths. Host code reports an error by calling `EXTERR` with A = error number and the message in-line (CMOS: `LD A,214 / CALL EXTERR / DEFM 'File not found' / DEFB 0`).

### 2.1 How the ports split the work

| Port | Base | Assembler | Host layer | Licence | Fit for retro-z80 |
|------|------|-----------|------------|---------|-------------------|
| Generic CP/M (Russell) | v5 | SLR z80asm/link; z88dk via PainfulDiodes | CMOS (BDOS files, editor) + DIST (256-byte patch) | zlib | Best reference for the minimal set; replace BDOS |
| Acorn Z80 2nd processor (Russell) | v5 | as above | ACORN (graphics and sound via VDU, OSWORD, OSBYTE) + AMOS | zlib | **ACORN.Z80 is reusable whole** if retro-z80's MOS offers Acorn-style OSWRCH, OSWORD and OSBYTE and a VDU driver |
| Agon Light "BBC BASIC v5" (Belfield) | v5 | Zilog ZDS II; `tools/transform_source.py` converts the source | Uses Russell's ACORN.Z80 + new `agon_os.asm` (28 KB of source), graphics, sound, interrupts | zlib | Shows that v5 + ACORN.Z80 + a custom OS layer works. Its VDU goes to the ESP32 VDP, so there is no local drawing code. https://github.com/breakintoprogram/agon-bbc-basic-v |
| ZX Spectrum Next (Belfield) | v3.00 | **sjasmplus**, MODULEs, `@` globals; some Z80N code under `BUILD_Z80N` | `patch.z80` (hooks), `next_io` (VDU engine: VDU 8–31 incl. 17, 18, 19, 22, 23, 25, 29), `next_graphics*` (PLOT, lines, triangles on ULA and Layer 2), `next_dos` (esxDOS RST 8 calls: f_open, f_read...), `next_sound` (AY), `editor.z80`, RTC, DMA, mouse, sprites | zlib | Closest hardware (same board family, sjasmplus), but v3 and Z80N-specific. Its VDU, PLOT and editor code is the most reusable. https://github.com/breakintoprogram/next-bbc-basic |
| Cerberus 2080 (Belfield) | v3.00 | sjasmplus, plain Z80 | 40×30 character-mapped screen, files via an ATmega mailbox, small graphics and sound. About 1,100 lines of host code | BASIC zlib; rest MIT | The simplest sjasmplus template for "text console + coprocessor files". https://github.com/breakintoprogram/cerberus |
| Agon (v3, Belfield) | v3 | ZDS II | MOS API via RST 8 | zlib | Less relevant (eZ80 toolchain) |
| eZ80-for-RC (dinoboards) | v5 fork | | eZ80 ADL mode | | Not a plain Z80. https://codeberg.org/dinoboards/eZ80-for-rc-basic |
| BeanZee / Marvin (PainfulDiodes) | v5 | z88dk-z80asm | BASIC built into a monitor firmware (BSD-3 monitor) | zlib + BSD-3 | A v5 ROM-embedded example; worth a look **[not read in detail]** |

I found no RC2014 or Z180 Z80 port of BBCZ80 in Russell's repository or its forks. The only RC port is the eZ80 one.

## 3. Graphics, sound, files and keyboard in the ports

- **Graphics (Acorn model, ACORN.Z80).**
  - MODE n sends `VDU 22,n`, CLG sends `VDU 16`, COLOUR n sends `VDU 17,n`, and `COLOUR l,r,g,b` sets the palette with VDU 19.
  - GCOL sends `VDU 18,a,n`. MOVE, DRAW, PLOT, CIRCLE, RECTANGLE and FILL all become `VDU 25,k,x;y;` sequences, and ORIGIN becomes `VDU 29`.
  - POINT is OSWORD 9, MODE (the function) is OSBYTE 135, and POS/VPOS is OSBYTE 134.
  - So **all drawing lives in the MOS's VDU driver.**
  - The Next port does the same inside its own `OSWRCH`: a VDU state machine with parameter buffering, then plot, line and triangle routines on 1280×1024 BBC coordinates, scaled to the screen.
- **Sound.** SOUND is OSWORD 7 and ENVELOPE is OSWORD 8 (ACORN.Z80). The Next drives AY chips (`next_sound.z80`). On retro-z80, sound is parked (Q1), so SOUND could drive the beeper or stay "Sorry" for now.
- **Time.** TIME is OSWORD 1/2 and TIME$ is OSWORD 14/15 (ACORN). CMOS uses a RunCPM-only BDOS 248 tick. retro-z80 has a 100 Hz timer recipe in spec 9 for exactly this (`docs/spec/timers.md`).
- **Files.**
  - CMOS uses CP/M FCBs: 8.3 names, `.BBC` default extension, 128-byte records, up to 7 open files, buffers taken from FREE (166 bytes each).
  - The Next port uses NextZXOS/esxDOS FAT calls (`RST 8`, `f_open`/`f_read`/`f_write`/`f_seek`/`f_opendir`...) and implements `*LOAD`, `*SAVE`, `*.`, `*CD`, OPENIN/OUT/UP, BGET, BPUT, PTR and EXT.
  - Cerberus asks a coprocessor.
  - retro-z80 has no DOS, so the MOS needs its own **FAT driver on the SD card** (spec 11), or a ready-made one. Size for a small Z80 FAT16/32 read/write driver: about 3–5 KB **[estimate, unconfirmed]**.
- **Keyboard.**
  - CMOS reads keys through BDOS 6. OSLINE is a full line editor; its keys come from DIST's configuration bytes at 0x1F0, reached through `IX=200H` (a CP/M-image assumption to remove).
  - The Next scans its keyboard itself, with key repeat, and checks for ESCAPE on the interrupt.
  - retro-z80 already plans a decoder and layout table in the boot ROM that BASIC's INKEY and GET read (`docs/spec/input.md`). ESCAPE should be set by the keyboard interrupt, as the Next does.

## 4. "ROM option" choices for retro-z80

Facts the options rest on:
- The boot ROM is 32 KB of block RAM, pages `0x3FC`–`0x3FF`, mapped in windows 0–1 at reset (spec 7 section 4).
- The console font (2 KB) lives in the ROM.
- The boot ROM also holds the monitor, the SD loader and the console driver.
- Page `0x3FB` = NONE makes a window read-only (spec 2 section 9.6).
- Pages `0x200`–`0x3F7` and `0x3F9`–`0x3FA` are reserved.
- SRAM keeps its contents over every reset except power-on.

Size budget:
- Core: 16,374 bytes.
- MOS: about 6–12 KB **[estimate]**. That is ~0.5–1 KB for the VDU text console on the tile map, ~0.7 KB for the OSLINE editor (CMOS's), ~1 KB for *commands, 3–5 KB for FAT and files, 2–3 KB for VDU 25 graphics, plus time, keyboard and ESCAPE.
- RAM: DATA 768 bytes + MOS workspace (~0.5–1 KB) + file buffers from the heap.

| | (a) In the 32 KB boot ROM | (b) Image in SRAM, write page NONE | (c) Extra block RAM in the bitstream |
|-|-|-|-|
| Size limit | 32 KB shared: core 16 KB leaves 16 KB for monitor + loader + console + font 2 KB + MOS | None in practice (any SRAM pages) | Whatever blocks remain: 16 KB = 8 × 18 Kb blocks, 32 KB = 16 |
| What it needs | Fit is very tight. Probably a cut-down MOS: text console, editor, files, no graphics, with SD/FAT shared with the boot loader. The core sits in two ROM pages; the MOS and monitor share the other two (page 3 is also the NMI monitor page) | The boot ROM loads `BASIC.ROM` (or similar) from SD or serial into SRAM pages, maps them read-only, and jumps. The boot ROM's existing "boot file" path (spec 7 step 7) almost covers this. A checksum lets a warm reset skip the reload | New ROM page numbers. 0x3F9–0x3FA (16 KB) are free next to REGS, and the 0x200–0x3F7 range is free too. A second bitstream-loaded memory with the same ROMWE rules |
| Pros | Always there, even with no SD card; matches D10 "boot ROM monitor, then BBC BASIC" | Full-size MOS with graphics; updated by copying a file; no FPGA rebuild; no block RAM | Always there, like (a), with room for a full MOS; no SRAM cycles for fetches |
| Cons | Little room; monitor and BASIC compete; changes need a bitstream reload (or ROMWE for development) | Needs a working SD card or a serial upload at power-on; uses SRAM pages | Costs block RAM: easy on the KS3 (100 blocks), tight on the KS2 (50 blocks, already 16 for the boot ROM plus palettes and FIFOs). Spec changes in memory.md and system.md |

A possible 64 KB map for any of the three **[proposal, not from a source]**:

| Window | Addresses | Contents |
|--------|-----------|----------|
| 0 | `0x0000`–`0x1FFF` | MOS: vectors, `0x0066` NMI, IM 2 handlers and table, entry points, VDU, editor |
| 1–2 | `0x2000`–`0x5FFF` | Core, 16 KB, read-only |
| 3–7 | `0x6000`–`0xFFFF` | RAM: DATA at `0x6000` (page-aligned), MOS workspace, PAGE ≈ `0x6400`, HIMEM ≈ `0xFF00` (stack below it). That leaves ≈ 39 KB for BASIC, against ≈ 48 KB under CP/M (bbcbasic.co.uk) |

Further MOS pages (FAT, graphics) and the bitmap layers would be banked into a window on demand, through a trampoline. Drawing into a bitmap needs a window the MOS can borrow, which reduces HIMEM or means a temporary swap of a user page. ACORN.Z80's fixed `&FFEE`/`&FFF1`/`&FFF4` calls can either point at labels (change the EQUs) or use a jump block at the top of RAM.

## 5. Risks

- **tv80 and R.** `RUN` seeds RND with `RAND: LD A,R / JR Z,RAND` (EXEC.Z80). If the core's R register stayed at 0, **RUN would hang**. Check that tv80 increments R (ZEXALL does not test R) **[unconfirmed for tv80]**.
- **Undocumented instructions.** The core uses none: there is no IXH, IXL, IYH, IYL or SLL in the source, and the `DEFB 0DDH/0EDH/0FDH/0CBH` bytes in MAIN are keyword tokens. Only CP/M DIST checks P/V after INC to detect a Z80. ASMB assembles only documented instructions; user code may still use undocumented ones. ZEXDOC/ZEXALL in phase 1 (Q3) covers the rest.
- **Registers.** The core keeps numbers in HL'/DE'/BC' (EXX) and the text pointer in IY. ISRs must save the alternate set, IX and IY, or avoid using them. Using EXX in an ISR is the classic way to break BBC BASIC.
- **Timing.** The core has no delay loops. WAIT, INKEY(n) and TIME all go through GETIME/OSKEY, so they need a working 100 Hz TIME. CMOS's TICKS uses RunCPM's BDOS 248, which must be replaced.
- **CP/M assumptions (all in CMOS and DIST, none in the core).**
  - BDOS `CALL 5`; FCB at `5CH`; command tail at `80H` (auto-CHAIN); HIMEM from `(6)`; `RST 0` for BYE.
  - 8.3 upper-case names and 128-byte records (EXT up to &800000).
  - CTRL-S pauses output, and printer output goes through BDOS 5.
  - OSLINE reads its key table at `IX=200H` (DIST's 0x1F0 block).
  - These are the reason to write a new MOS rather than patch CMOS.
- **Name.** "BBC BASIC" may not be carried over to "a derived or forked work" (README). Dean Belfield's ports still use the name. How to name the retro-z80 build is **an open point** (perhaps ask R. T. Russell).
- **Version choice.**
  - v5 is current, holds BASIC V, and its core just fits in 16 KB, but no sjasmplus port exists; the conversion is small, as shown above.
  - The sjasmplus ports (Next, Cerberus) are v3, with v3 token values: PUT's token changed from &CE to &0E in v5, so v3 programs saved tokenised may need fixing.
  - A likely path **[recommendation]**: v5 core + ACORN.Z80 + a new retro-z80 MOS, borrowing VDU, PLOT and editor ideas from the Next and Cerberus ports.
- **64 KB limit.** BASIC programs and data share ≈ 39–48 KB. The core has no banked memory.

## Cited URLs

- https://github.com/rtrussell/BBCZ80 (README, licence.txt, WHATSNEW.TXT, src/*.Z80, bin/*/MAKE.SUB)
- https://www.bbcbasic.co.uk/bbcbasic/z80basic.html
- https://www.osnews.com/story/130145/r-t-russells-z80-bbc-basic-is-now-open-source/
- https://github.com/breakintoprogram/next-bbc-basic
- https://github.com/breakintoprogram/cerberus
- https://github.com/breakintoprogram/agon-bbc-basic
- https://github.com/breakintoprogram/agon-bbc-basic-v
- https://github.com/PainfulDiodes/BBCZ80 (building-BBCZ80.md, convert.sh)
- https://github.com/PainfulDiodes/marvin
- https://codeberg.org/dinoboards/eZ80-for-rc-basic
- https://github.com/hirosuzuki/BBCZ80-pasmo
