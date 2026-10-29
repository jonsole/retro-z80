; Example 1-1 (docs/guide/system.md): one page in two windows, then a
; read-only window. SRAM page 0x020 (physical 0x040000) goes into windows 5
; and 6. A string written through window 6 is printed through window 5:
; the same memory. Then window 6's write page becomes NONE, and a write
; through it changes nothing. Windows 5 and 6 get their own pages back
; before the program ends.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PG_NONE equ     0x3FB                   ; reads 0xFF, ignores writes (memory spec, section 9.3)
PAGE    equ     0x020                   ; an SRAM page this program does not use
WIN5    equ     0xA000
WIN6    equ     0xC000

start:  ld      hl,PAGE
        ld      bc,MMU6_0_P             ; window 6's read page: byte 0 is held ...
        out     (c),l
        inc     b                       ; ... MMU6_1 commits it, and the write page too
        out     (c),h
        ld      bc,MMU5_0_P             ; the same page in window 5
        out     (c),l
        inc     b
        out     (c),h

        ld      hl,text                 ; write the string through window 6
        ld      de,WIN6
        ld      bc,TEXTLEN
        ldir
        ld      hl,s_read
        rst     0x18                    ; PUTS
        ld      hl,WIN5                 ; and print it from window 5
        rst     0x18

        ld      hl,PG_NONE              ; window 6: reads page 0x020, writes go nowhere
        ld      bc,MMU6W_0_P
        out     (c),l
        inc     b
        out     (c),h
        ld      a,'J'
        ld      (WIN6),a                ; ignored: "Hello" stays
        ld      hl,s_ro
        rst     0x18
        ld      hl,WIN5
        rst     0x18

        ld      hl,6                    ; windows 5 and 6 back to the program map
        ld      bc,MMU6_0_P             ; (committing a read page sets the write page)
        out     (c),l
        inc     b
        out     (c),h
        dec     l
        ld      bc,MMU5_0_P
        out     (c),l
        inc     b
        out     (c),h
        ret

text:   db      "Hello from page 020", 13, 10, 0
TEXTLEN equ     $ - text
s_read: db      13, 10, "Written via window 6, read via 5: ", 0
s_ro:   db      "Window 6 read-only, 'J' written:  ", 0
