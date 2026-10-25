; The monitor's help (H or ?), in ROM page 2, included by boot.asm
helptext:
        db      "D[.s] [addr [count]]     dump memory (Enter: carry on)", 13, 10
        db      "E[.s] addr [value ...]   enter values or ", '"', "text", '"', "; no values: step through", 13, 10
        db      "                         (Enter keeps, - goes back, . or Esc ends)", 13, 10
        db      "F[.s] addr count value   fill", 13, 10
        db      "C addr count dest        copy", 13, 10
        db      "V addr count addr2       compare", 13, 10
        db      "S[.s] addr count value.. search (Enter: carry on)", 13, 10
        db      "G [addr [break]]         go, with one breakpoint (ROM too)", 13, 10
        db      "N                        step one instruction (Enter: step again)", 13, 10
        db      "R [name value]           show or set the program's registers", 13, 10
        db      "P port [value]           read or write an I/O port (register:page)", 13, 10
        db      "I [addr [count]]         disassemble (Enter: carry on)", 13, 10
        db      "T [addr count]           test memory, destroying it; alone: all SRAM", 13, 10
        db      "H or ?                   this list", 13, 10
        db      "Hex numbers. .B .W .L: byte, word, long. P in front of an address:", 13, 10
        db      "physical (P1FC000). Tab or EDIT on an empty line: the tape demo;", 13, 10
        db      "F1 or GRAPH: the sprite demo (BREAK or Esc ends it).", 13, 10, 0
