---
name: writing-programmer-guide
description: Writes, restyles or reviews a chapter of retro-z80's programmer's guide (docs/guide) in the style of the Amiga Hardware Reference Manual, with worked examples tried on the KS2. Use for a new guide chapter, restyling or checking an existing one, or adding an example to the guide.
---

# Writing a programmer's guide chapter

The guide (`docs/guide/`) teaches a Z80 programmer to use the hardware, chapter by chapter, as the **Amiga Hardware Reference Manual** taught the Amiga's. Its specs (`docs/spec/`) are the source of truth: the chapter agrees with them and with what the RTL actually builds.

## Steps

1. **Gather.** Read the chapter's ticket, its spec(s), the RTL for what is built (a register in the spec may not be wired; check `fpga/rtl/retroz80.v`), and the names in `firmware/include/hw.inc`. Read retro68k's guide chapter on the same unit (`../retro68k/docs/guide/`) for what to cover. Done when you can list every register, bit and behaviour the chapter covers, each marked built or not.
2. **Plan** the chapter in the manual's shape (below): its sections and its complete examples. Done when every register of the unit has a home and every example has a purpose a reader would want.
3. **Write and try the examples** in `examples/<topic>/`. Assemble each with sjasmplus (`--sld`), wrap it with `rlink.py image`, run it on the KS2 through the MCP tools (`launch`, `screen_capture`, `screen_record`, `read_console`, `type_text`), and check it does what the text will say. Measure what can be measured (times, rates) and quote the board's figures. Anything that misbehaves gets a GitHub ticket, and the chapter says what is not built. Done when every complete example has run on the board, and the result is seen in a capture or the console.
4. **Write the chapter** to the rules below.
5. **Check it**, rule by rule, against the whole file: every bit table top bit first, every table numbered, every encoding worked from the assembler's output (assemble the instructions and read the words back), no retro68k, British spelling. Done when every rule has been applied to every section.
6. **Land it.** A line for the chapter in `docs/HANDOFF.md`'s file table; a branch `guide-<topic>` from `origin/main`; a commit and a PR that says what was tried on the board and closes the ticket.

## The chapter's shape

As the manual's chapters:

1. **Introduction**: what the hardware does for the programmer, in a paragraph; a bullet list "This chapter covers"; what to read first.
2. **Conventions in this chapter**: the assembler, the include files, how the registers are reached (page, port form), where the examples are and what they assume (the program map, the boot ROM's console).
3. **The parts, one by one**, each under its own heading (for the copper: the instruction format, MOVE, WAIT, the registers). Each part: what it does, its bits, a short fragment.
4. **A working program built step by step**: a numbered list of steps ("Step 1: …" or 1–4), then the complete example.
5. **Advanced topics**, each with its example.
6. **Timing**, and **what it cannot do**, where they matter.
7. **Summary** sections: the instructions or registers, the state after reset and when a program starts, the equates in `hw.inc`.

Headings in Title Case for sections (`## Putting Together a Copper List`), sentence case below them. Sections separated by `---`.

## Rules

### Voice

- Plain short sentences, British spelling (colour, behaviour, centre), second person where a person acts ("write COP1LC", "you can").
- Say what the hardware does and what the programmer does about it. Comparisons with other machines, and every mention of **retro68k**, belong in the specs, never in the guide. The Amiga may be named where it helps a reader who knows it.
- What is not built yet is said plainly where it matters, with its ticket.

### Bit layouts

- A register with fields gets a **table of its bits, top bit first**: `Bits | Name | Meaning`, `7` … `0` (bits that read 0 or are reserved shown as such).
- An instruction or a packed word gets the same table **per word**: `Word | Bits | Meaning`, first word then second, top bit first in each.
- After the table, one **worked encoding** with a raw `DW` (or `DB`) line beside the macro or the source form, the numbers taken from the assembler's own output:

  ```asm
          DW      0xF00B,0x5828           ; WAIT for line 600, pixel 808
          CWAIT   600,808                 ; the same two words
  ```

- No encoding formulas (`0xF000 | (line >> 8) << 2`) in place of tables. Lists of codes go in code order, one row per code.

### Tables and figures

- **Every table is numbered** within its chapter and has a Title Case caption on the line above it: `**Table 5-3: WAIT Instruction Words**`, then the table. The text refers to it by number where that helps.
- **Figures** are ASCII drawings in a code block with the caption at the foot, centred (`Figure 5-1: A Copper Instruction`), or, for drawings to scale, SVG images in `docs/guide/img/` (drawn by `tools/guide_figures/`) with the caption on the line below. Figures and tables are numbered separately, in order.
- Table cells: short phrases; units and ranges stated (`0–255`, `µs`); hex as `0x1F`.

### Examples

- Each complete example is a file in `examples/<topic>/`, named in the chapter (`examples/copper/bars.asm`), numbered "Example 5-2" with a heading of its own and a one-line purpose in its opening comment.
- It starts with `device zxspectrum48`, `org 0x8000` and `include "hw.inc"`; it runs in the boot ROM's program map (a Z80 address is a physical address); it ends by putting back everything it changed (layers, copper, interrupts, the IM 2 table, CONMODE) and returning to the monitor.
- The chapter shows the complete program the first time, from its opening comment and `device` line as in the file; later examples may show only what is new, and name the file for the rest.
- Every fragment assembles. Comments explain why, at the line they belong to.
- The text quotes what the board showed: "on the board the change lands on the character boundary", "it took 45,366 µs".

### Registers

- Name registers and bits as `hw.inc` does (`COPCON_EN_M`, `SERSTAT1_P`, `INTB_SERIAL`).
- Reaching a register: the port form (`LD BC,name_P`, `OUT (C),r`) unless the chapter's conventions say otherwise.
- The summary table gives each register's number or offset, port, access (R, W, RW, W1C), and its bits in short.
