; Example 7-2 (docs/guide/serial.md): sending a block fast with OTIR. Fills
; 16 KB with 256 lines of text, sends them to the PC with OTIR, as much at a
; time as TXSPACE allows, and shows on the screen how long it took (TIME).

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

CONMODE equ     0x0E                    ; RST 28h functions
PUTDEC  equ     0x08
BUF     equ     0xA000                  ; 16 KB, windows 5 and 6
LEN     equ     0x4000

start:  ld      hl,title
        rst     0x18                    ; PUTS
        ld      a,0x05                  ; the console: screen and keyboards only
        rst     0x28
        db      CONMODE
        ld      (oldmode),a

        ld      de,BUF                  ; 256 lines of 64 bytes
.fill:  ld      hl,line
        ld      bc,64
        ldir
        ld      a,d
        cp      high (BUF+LEN)
        jr      nz,.fill

        call    time
        push    hl
        ld      hl,BUF
        ld      de,LEN
        call    sendblk
        call    time
        pop     de
        or      a
        sbc     hl,de                   ; microseconds, under 65 ms
        push    hl

        ld      a,(oldmode)             ; the console back
        rst     0x28
        db      CONMODE
        ld      hl,s_sent
        rst     0x18
        pop     hl
        rst     0x28
        db      PUTDEC
        ld      hl,s_us
        rst     0x18
        ret

; Send DE bytes from HL, as many at a time as there is room for.
; A, B, C, D, E, H, L changed.
sendblk:
.more:  ld      bc,SERSTAT0_P           ; TXSPACE: 0-255 (255: 255 or more)
        in      a,(c)
        or      a
        jr      z,.more                 ; no room yet
        ld      b,a                     ; B = the room ...
        ld      a,d
        or      a
        jr      nz,.go                  ; ... 256 or more left: all of it
        ld      a,e
        cp      b
        jr      nc,.go
        ld      b,e                     ; ... but no more than are left
.go:    ld      a,e                     ; DE = DE - B
        sub     b
        ld      e,a
        jr      nc,.nc
        dec     d
.nc:    ld      c,SERDATA_PORT          ; port 0x53: OTIR puts B on A15-A8
        otir                            ; 21 T-states a byte
        ld      a,d
        or      e
        jr      nz,.more
        ret

time:   ld      bc,TIME0_P              ; TIME bits 15-0 to HL
        in      l,(c)                   ; reading TIME0 captures all 32 bits
        inc     b
        in      h,(c)
        ret

oldmode: db     0
title:  db      13, 10, "Sending 16 KB to the PC with OTIR ...", 13, 10, 0
s_sent: db      "16,384 bytes in ", 0
s_us:   db      " us.", 13, 10, 0
line:   db      "The quick brown fox jumps over the lazy dog. 0123456789 ABCDEF", 13, 10
        ASSERT  $ - line == 64
