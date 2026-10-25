; The disassembler's test (ticket #23): a CP/M program for the ZEX testbench
; (tb_zex.v) that runs the boot ROM's disassembler (firmware/boot/disasm.asm)
; on every entry of disref.py's table (distab.bin) and prints, for each, a
; line "|n text": the length it found and its text. disref.py check
; compares the lines with its own. Each entry is disassembled at address
; 8000.

        DEVICE  NOSLOT64K
        org     0x0100
DISBUF  equ     0xE000
DISVAR  equ     0xE040

start:  ld      hl,(6)
        ld      sp,hl
        ld      hl,distab
.ent:   ld      a,(hl)                  ; the header: the bytes, 0x80 after RST 28h
        or      a
        jr      z,.done
        inc     hl
        ld      (ptr),hl
        ld      c,a
        and     0x7F
        add     a,l
        ld      l,a
        jr      nc,.n
        inc     h
.n:     ld      (next),hl
        ld      a,c
        rlca
        and     1
        ld      c,a
        ld      hl,0x8000
        call    dis
        ld      c,a
        ld      a,'|'
        out     (0),a
        ld      a,c
        add     a,'0'
        out     (0),a
        ld      a,' '
        out     (0),a
        ld      hl,DISBUF
.p:     ld      a,(hl)
        or      a
        jr      z,.nl
        out     (0),a
        inc     hl
        jr      .p
.nl:    ld      a,13
        out     (0),a
        ld      a,10
        out     (0),a
        ld      hl,(next)
        jr      .ent
.done:  ld      hl,s_end
.e:     ld      a,(hl)
        or      a
        jp      z,0
        out     (0),a
        inc     hl
        jr      .e
s_end:  db      "disassembled  OK", 13, 10, "Tests complete", 0

; The next byte of the entry
disget: push    hl
        ld      hl,(ptr)
        ld      a,(hl)
        inc     hl
        ld      (ptr),hl
        pop     hl
        ret
ptr:    dw      0
next:   dw      0

        include "disasm.asm"
distab: incbin  "distab.bin"
