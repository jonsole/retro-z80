; Example 7-3 (docs/guide/serial.md): an interrupt-driven link. The SERIAL
; handler fills a 256-byte receive ring and empties a 256-byte transmit
; ring; the program only calls sgetc and sputc, which never touch the
; FIFOs. TXREADY is enabled only while the transmit ring holds something.
; When the receive ring is full the handler leaves the bytes in the FIFO
; and turns RXREADY off, so the link's flow control holds the PC back;
; sgetc turns it on again.
; The program echoes in capitals, as Example 7-1, until Esc.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

CONMODE equ     0x0E                    ; RST 28h function
ESC     equ     27
RXBUF   equ     0x9000                  ; 256 bytes each, on 256-byte boundaries,
TXBUF   equ     0x9100                  ; so an 8-bit index wraps by itself
TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0

start:  ld      hl,title
        rst     0x18                    ; PUTS
        ld      a,0x05                  ; the console: screen and keyboards only
        rst     0x28
        db      CONMODE
        ld      (oldmode),a

        di
        ld      hl,TABLE                ; every entry to the spurious handler ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,serint               ; ... but the link's
        ld      (TABLE+2*INT_SERIAL),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,SERLEVEL_P           ; RXLEVEL 1 byte, TXLEVEL 1 byte (codes 1)
        ld      a,(1<<SERLEVEL_RXLEVEL_B)|(1<<SERLEVEL_TXLEVEL_B)
        out     (c),a
        ld      bc,SERIRQEN_P           ; RXREADY only: TXREADY when there is something to send
        ld      a,SERIRQEN_RXREADY_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_SERIAL<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_SERIAL)
        out     (c),a
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a
        ei

        ld      hl,hello
.hi:    ld      a,(hl)
        or      a
        jr      z,.loop
        call    sputc
        inc     hl
        jr      .hi
.loop:  call    sgetc
        jr      z,.loop                 ; nothing yet (the Z80 is free here)
        cp      ESC
        jr      z,.end
        cp      'a'
        jr      c,.put
        cp      'z'+1
        jr      nc,.put
        sub     'a'-'A'
.put:   call    sputc
        rst     0x08                    ; PUTC: on the screen
        jr      .loop

.end:   ld      hl,bye
.by:    ld      a,(hl)
        or      a
        jr      z,.drain
        call    sputc
        inc     hl
        jr      .by
.drain: ld      a,(tx_tail)             ; let the handler send it all
        ld      b,a
        ld      a,(tx_head)
        cp      b
        jr      nz,.drain

        di                              ; put everything back
        ld      bc,SERIRQEN_P
        xor     a
        out     (c),a
        ld      bc,SERLEVEL_P
        out     (c),a
        ld      bc,INTCON_P
        out     (c),a
        ld      bc,INTENA0_P+(INTR_SERIAL<<8)
        ld      a,1<<INTB_SERIAL
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ld      a,(oldmode)
        rst     0x28
        db      CONMODE
        ret

; SERIAL: take every byte waiting, send what the FIFO has room for.
serint: push    af
        push    bc
        push    hl
.rx:    ld      a,(rx_head)
        ld      l,a
        inc     a                       ; the next place
        ld      h,a
        ld      a,(rx_tail)
        cp      h
        jr      z,.full                 ; ring full: leave the rest in the FIFO
        ld      bc,SERSTAT1_P           ; RXCOUNT
        in      a,(c)
        or      a
        jr      z,.tx                   ; all taken: RXREADY goes off by itself
        ld      a,h
        ld      (rx_head),a             ; (the byte is stored before sgetc can look:
        ld      h,high RXBUF            ;  interrupts are off in here)
        in      a,(SERDATA_PORT)
        ld      (hl),a
        jr      .rx
.full:  ld      bc,SERIRQEN_P           ; RXREADY off until sgetc makes room
        in      a,(c)
        and     ~SERIRQEN_RXREADY_M
        out     (c),a
.tx:    ld      a,(tx_tail)
        ld      l,a
        ld      h,high TXBUF
.txl:   ld      a,(tx_head)
        cp      l
        jr      z,.txoff                ; the ring is empty
        ld      bc,SERSTAT0_P           ; TXSPACE
        in      a,(c)
        or      a
        jr      z,.txend                ; the FIFO is full: TXREADY brings us back
        ld      a,(hl)
        out     (SERDATA_PORT),a
        inc     l
        jr      .txl
.txoff: ld      bc,SERIRQEN_P           ; nothing to send: TXREADY off, or it never stops
        in      a,(c)
        and     ~SERIRQEN_TXREADY_M
        out     (c),a
.txend: ld      a,l
        ld      (tx_tail),a
        pop     hl
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei
        reti

; Queue A to send, waiting while the ring is full. Registers kept.
sputc:  push    af
        push    bc
        push    hl
        ld      c,a
        ld      a,(tx_head)
        ld      l,a
        ld      h,high TXBUF
        ld      (hl),c
        inc     a
        ld      b,a
.full:  ld      a,(tx_tail)
        cp      b
        jr      z,.full                 ; full: wait for the handler
        ld      a,b
        ld      (tx_head),a
        di                              ; TXREADY on, after tx_head has moved
        ld      bc,SERIRQEN_P           ; (SERIRQEN's other bits kept)
        in      a,(c)
        or      SERIRQEN_TXREADY_M
        out     (c),a
        ei
        pop     hl
        pop     bc
        pop     af
        ret

; A = the next byte received, with NZ; Z if there is none. B, C, H, L changed.
sgetc:  ld      a,(rx_head)
        ld      b,a
        ld      a,(rx_tail)
        cp      b
        ret     z                       ; empty
        ld      l,a
        ld      h,high RXBUF
        inc     a
        ld      (rx_tail),a             ; room again: RXREADY back on
        di                              ; (SERIRQEN's other bits kept)
        ld      bc,SERIRQEN_P
        in      a,(c)
        or      SERIRQEN_RXREADY_M
        out     (c),a
        ei
        ld      a,(hl)
        or      0xFF                    ; NZ ...
        ld      a,(hl)                  ; ... with the byte (LD keeps the flags)
        ret

rx_head: db     0                       ; written by the handler
rx_tail: db     0                       ; written by the program
tx_head: db     0                       ; written by the program
tx_tail: db     0                       ; written by the handler
oldmode: db     0
title:  db      13, 10, "Echoing the link with interrupts. Esc from the PC ends it.", 13, 10, 0
hello:  db      "Interrupt-driven: type something.", 13, 10, 0
bye:    db      13, 10, "Bye.", 13, 10, 0
