; Example 7-1 (docs/guide/serial.md): sending and receiving bytes. The
; program takes the link from the boot ROM's console (CONMODE: the screen
; and the keyboards only), then sends back in capitals every byte the PC
; sends, and shows it on the screen too. Esc from the PC ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

CONMODE equ     0x0E                    ; RST 28h functions
PUTDEC  equ     0x08
ESC     equ     27

start:  ld      hl,title
        rst     0x18                    ; PUTS, on the screen and the link
        ld      a,0x05                  ; the console: print on the screen (bit 0),
        rst     0x28                    ; keys from the keyboards (bit 2); the link
        db      CONMODE                 ; is the program's
        ld      (oldmode),a

        ld      hl,hello                ; straight to the PC
        call    sputs
.loop:  call    getc                    ; a byte from the PC
        cp      ESC
        jr      z,.end
        cp      'a'                     ; small letters to capitals
        jr      c,.put
        cp      'z'+1
        jr      nc,.put
        sub     'a'-'A'
.put:   call    putc                    ; back to the PC ...
        rst     0x08                    ; ... and on the screen (PUTC: the screen only now)
        ld      hl,(count)
        inc     hl
        ld      (count),hl
        jr      .loop

.end:   ld      hl,bye
        call    sputs
        ld      a,(oldmode)             ; the console as it was
        rst     0x28
        db      CONMODE
        ld      hl,s_count
        rst     0x18
        ld      hl,(count)
        rst     0x28
        db      PUTDEC
        ld      hl,s_bytes
        rst     0x18
        ret

; Send A to the PC, waiting for room. A kept; B, C, E changed.
putc:   ld      e,a
.wait:  ld      bc,SERSTAT0_P           ; TXSPACE: room in the transmit FIFO
        in      a,(c)
        or      a
        jr      z,.wait                 ; none yet
        ld      a,e
        out     (SERDATA_PORT),a        ; port 0x53, whatever the high byte
        ret

; Wait for a byte from the PC: A = the byte. B, C changed.
getc:   ld      bc,SERSTAT1_P           ; RXCOUNT: bytes waiting
        in      a,(c)
        or      a
        jr      z,getc                  ; nothing yet: SERDATA would read 0x00
        in      a,(SERDATA_PORT)        ; take one
        ret

; Send the string at HL, ending with 0x00.
sputs:  ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      sputs

oldmode: db     0
count:  dw      0
title:  db      13, 10, "Echoing the link in capitals. Esc from the PC ends it.", 13, 10, 0
hello:  db      "Type something; it comes back in capitals.", 13, 10, 0
bye:    db      13, 10, "Bye.", 13, 10, 0
s_count: db     13, 10, "Echoed ", 0
s_bytes: db     " bytes.", 13, 10, 0
