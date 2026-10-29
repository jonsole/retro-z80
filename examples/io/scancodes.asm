; Example 8-2 (docs/guide/io.md): the PS/2 keyboard's scan codes.
; Reads the bytes from the PS/2 FIFO itself and prints one line per key
; going down or up, such as "down 1C" and "up E0 75", with the ROM's
; PUTS and PUTHEX. Keys typed from the PC (the link's KEY command) arrive
; the same way. Esc, pressed, goes back to the monitor.
;
; The program never calls GETC or POLLC, which would take bytes from the
; same FIFO.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h functions (boot ROM spec, section 7.3)

start:  ld      hl,title
        rst     0x18                    ; PUTS
        ld      d,0                     ; D bit 0: F0 seen (a release); bit 1: E0 seen

.wait:  ld      bc,KBSTAT_P
        in      a,(c)
        and     KBSTAT_COUNT_M          ; bytes waiting
        jr      z,.wait
        in      a,(KBDATA_PORT)         ; take one
        cp      0xF0
        jr      z,.release
        cp      0xE0
        jr      z,.extended

        ; a key's code: print the event, then start afresh
        ld      e,a
        ld      hl,s_down
        bit     0,d
        jr      z,.say
        ld      hl,s_up
.say:   rst     0x18
        bit     1,d
        jr      z,.code
        ld      hl,s_e0
        rst     0x18
.code:  ld      a,e
        rst     0x28
        db      PUTHEX
        ld      hl,s_nl
        rst     0x18
        ld      a,d                     ; Esc pressed (76, no prefix): done
        or      a
        jr      nz,.again
        ld      a,e
        cp      0x76
        ret     z                       ; RET goes to the ROM's EXIT
.again: ld      d,0
        jr      .wait

.release:
        set     0,d
        jr      .wait
.extended:
        set     1,d
        jr      .wait

title:  db      13, 10, "Scan codes. Esc ends.", 13, 10, 0
s_down: db      "down ", 0
s_up:   db      "up   ", 0
s_e0:   db      "E0 ", 0
s_nl:   db      13, 10, 0
