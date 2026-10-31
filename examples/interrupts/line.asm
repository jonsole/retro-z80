; Example 2-5 (docs/guide/interrupts.md): the LINE interrupt, BEAMPOS and
; FRAMECOUNT. First FRAMECOUNT is read either side of 100 vertical blanks.
; Then the LINE handler changes the background colour every 32 lines,
; moving LINECMP on each time, so the border shows 18 bands. LINE comes on
; the line before each band, and the handler writes BGCOLOR there: it is
; read at the start of the next line's picture, so each band starts
; cleanly on its first line. On entry the handler reads BEAMPOS, to check
; it was called on line LINECMP and to note how far into the line it
; started. A key ends it and prints what it saw. The main
; loop waits with HALT before each ROM call, so the call never holds a LINE
; back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0
FIRST   equ     VID_Y0-1                ; LINE on the line before the first band (the picture's first line)
BAND    equ     32                      ; lines a band
PUTDEC  equ     0x08                    ; RST 28h functions

start:  ld      hl,title
        rst     0x18                    ; PUTS

        ; ---- FRAMECOUNT across 100 frames
        di                              ; (no handler reads a capture now, but the habit is good)
        ld      bc,FRAMECOUNT0_P
        in      l,(c)                   ; captures both bytes
        inc     b
        in      h,(c)
        ei
        push    hl
        ld      d,100
        ld      bc,VIDSTAT_P
.frame: ld      a,VIDSTAT_VBLANK_M      ; clear the flag, then wait for it
        out     (c),a
.vb:    in      a,(c)
        and     VIDSTAT_VBLANK_M
        jr      z,.vb
        dec     d
        jr      nz,.frame
        di
        ld      bc,FRAMECOUNT0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ei
        pop     de
        or      a
        sbc     hl,de                   ; frames counted
        push    hl
        ld      hl,fcmsg
        rst     0x18
        pop     hl
        rst     0x28
        db      PUTDEC
        ld      hl,crlf
        rst     0x18

        ; ---- the LINE interrupt
        di
        ld      hl,TABLE                ; every entry to the spurious handler ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,line                 ; ... but LINE's
        ld      (TABLE+2*INT_LINE),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,LINECMP0_P           ; the first band's line
        ld      a,low FIRST
        out     (c),a
        inc     b
        ld      a,high FIRST
        out     (c),a
        ld      bc,VIDSTAT_P            ; no old LINE
        ld      a,VIDSTAT_LINE_M
        out     (c),a
        ld      bc,VIDINTEN_P           ; 1. the unit's enable
        in      a,(c)
        or      VIDINTEN_LINE_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_LINE<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_LINE)
        out     (c),a                   ; 2. the controller's
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a                   ; 3. the master enable
        ei                              ; 4. the CPU's

        ld      hl,keymsg
        rst     0x18
.main:  halt                            ; wait for a LINE first: the ROM's calls run
        rst     0x20                    ; with interrupts off, so a POLLC begun just
        jr      z,.main                 ; after a LINE is done long before the next

        di                              ; put everything back
        ld      bc,INTCON_P
        xor     a
        out     (c),a
        ld      bc,INTENA0_P+(INTR_LINE<<8)
        ld      a,1<<INTB_LINE          ; SETCLR 0: clear
        out     (c),a
        ld      bc,VIDINTEN_P
        in      a,(c)
        and     ~VIDINTEN_LINE_M
        out     (c),a
        ld      bc,LINECMP0_P
        xor     a
        out     (c),a
        inc     b
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        xor     a
        out     (ULA_PORT),a            ; border (BGCOLOR) black
        ei

        ld      hl,cntmsg               ; what the handler saw
        rst     0x18
        ld      hl,(count)
        rst     0x28
        db      PUTDEC
        ld      hl,badmsg
        rst     0x18
        ld      hl,(bad)
        rst     0x28
        db      PUTDEC
        ld      hl,latemsg
        rst     0x18
        ld      hl,(latest)
        rst     0x28
        db      PUTDEC
        ld      hl,endmsg
        rst     0x18
        ret

; LINE: at the start of beam line LINECMP. Read where the beam is, set the
; next line's background, and ask for the next band's line.
line:   push    af
        push    bc
        push    de
        push    hl
        ld      bc,BEAMPOS0_P           ; captures all four bytes
        in      e,(c)
        inc     b
        in      d,(c)                   ; DE = hpixel
        inc     b
        in      l,(c)
        inc     b
        in      h,(c)                   ; HL = vline
        ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_LINE_M
        out     (c),a                   ; clear the cause first

        push    hl
        ld      hl,(latest)             ; the latest start in a line so far
        or      a
        sbc     hl,de
        jr      nc,.early
        ld      (latest),de
.early: ld      hl,(count)
        inc     hl
        ld      (count),hl
        pop     hl
        ld      de,(next)               ; was it the line asked for?
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      z,.right
        ld      de,(bad)
        inc     de
        ld      (bad),de
.right: ld      a,(colour)              ; the next band's colour: 3 bytes in colours
        ld      e,a
        add     a,a
        add     a,e
        ld      e,a
        ld      d,0
        ld      hl,colours
        add     hl,de
        ld      bc,BGCOLOR0_P
        ld      a,(hl)                  ; blue
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)                  ; green
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)                  ; red: the colour is complete, and shows
        out     (c),a                   ; from the next line's picture
        ld      a,(colour)
        inc     a
        and     7
        ld      (colour),a
        ld      hl,(next)               ; the next band, or the first again
        ld      de,BAND
        add     hl,de
        ld      de,BEAM_H-1
        or      a
        sbc     hl,de                   ; the last line (624), or past it?
        add     hl,de                   ; (HL back; ADD leaves Z and S as SBC set them)
        jp      m,.set
        ld      hl,FIRST                ; yes: next frame's first band
        xor     a
        ld      (colour),a
.set:   ld      (next),hl
        ld      bc,LINECMP0_P
        out     (c),l
        inc     b
        out     (c),h
        pop     hl
        pop     de
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei                              ; NONE, or a source nobody asked for
        reti

colours: db     0x00,0x00,0x00          ; blue, green, red: black,
        db      0xD7,0x00,0x00          ; blue,
        db      0x00,0x00,0xD7          ; red,
        db      0xD7,0x00,0xD7          ; magenta,
        db      0x00,0xD7,0x00          ; green,
        db      0xD7,0xD7,0x00          ; cyan,
        db      0x00,0xD7,0xD7          ; yellow,
        db      0xD7,0xD7,0xD7          ; white
next:   dw      FIRST                   ; the line LINECMP holds
colour: db      0
count:  dw      0                       ; LINE interrupts taken
bad:    dw      0                       ; ... on a line other than LINECMP
latest: dw      0                       ; the latest hpixel seen on entry
title:  db      13, 10, "LINECMP, BEAMPOS and FRAMECOUNT.", 13, 10, 0
fcmsg:  db      "Frames counted over 100 vertical blanks: ", 0
keymsg: db      "Bands every 32 lines. A key ends it.", 13, 10, 0
cntmsg: db      "LINE interrupts: ", 0
badmsg: db      ", on the wrong line: ", 0
latemsg: db     ", latest start: beam pixel ", 0
endmsg: db      13, 10, 0
crlf:   db      13, 10, 0
