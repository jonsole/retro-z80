; The boot console (spec 7, section 5.1; ticket #15), included by boot.asm:
; 80 x 30 characters on layer L0 as a 1 bpp tile map, in the 640 x 480
; window in the middle of the picture, with the 8 x 8 font (font.inc, made
; by tools/mkfont.py from font8x8) shown 2x tall.
;
;   Map      128 x 32 entries (CTRL3: MAPW 2, MAPH 0) at SRAM 0x1FC000 (page
;            0x0FE), mapped at 0x8000 (window 4). An entry is the character
;            code (TILE) and the colour pair (PAL = pair + 1, bits 4-1 of
;            the high byte); columns 0-79 of rows 0-31 are used. Map row r is
;            at 0x8000 + 256r, so an entry's address is a high byte of 0x80
;            + row and a low byte of 2 x column
;   Font     the patterns at SRAM 0x1FE000 (page 0x0FF), mapped at 0xA000
;            (window 5) and copied from the ROM; the console's workspace
;            follows it at 0xA800
;   Colours  PALETTE0 pairs: entry 16(p + 1) the paper, 16(p + 1) + 1 the ink
;   Screen   rows 0-28 are text, row 29 the status line: "retro-z80", the
;            joysticks (J1 through the Kempston port, J2: the letters U D L
;            R 1 2 A S lit while pressed), port 0xFE with all rows (FE, in
;            hex), the last PS/2 byte (KB) and the seconds since the console
;            started (timer 0). Text scrolls by SCROLLY, a map row (8 source
;            lines) at a time, wrapping at 32 rows; the status line is drawn
;            again on the new bottom row each time
;
; conprep (with interrupts off: it moves SP) maps the pages, copies the
; font, clears the map and prints the start-up text, all before the layer
; shows it. convbl, called by the VBLANK handler every frame, switches L0
; from the palette chart to the console CON_FRAMES frames after the
; interrupts start (the palette writes need the chart gone). cputc prints a
; character; conkey echoes a byte from the serial link, or a key typed on
; the membrane or a PS/2 keyboard (keys.asm), on the screen and back to the
; PC; constat redraws the status line and the cursor (the main loop calls it
; when timer 0 or a change of the inputs has set CDIRTY).
;
; The cursor is an underscore that blinks with timer 0: shown while the
; background is bright, gone while it is dim.

CMAP    equ     0x8000                  ; window 4: SRAM page 0x0FE, physical 0x1FC000
CFONT   equ     0xA000                  ; window 5: SRAM page 0x0FF, physical 0x1FE000
CWS     equ     0xA800                  ; the console's workspace (spec 7, section 5.1)
CROW    equ     CWS + 0                 ; the cursor's row on the screen, 0-28
CCOL    equ     CWS + 1                 ; ... and column, 0-79
CTOP    equ     CWS + 2                 ; the map row at the top of the screen, 0-31
CATTR   equ     CWS + 3                 ; entries' high byte: the colour pair's PAL x 2
CSP     equ     CWS + 4                 ; 2 bytes: SP while conprep fills the map
CUNDER  equ     CWS + 6                 ; 2 bytes: the map entry under the cursor

; Kept by the interrupt handlers, in window 6 after boot.asm's variables
CWAIT   equ     0xC00B                  ; frames until the console shows
CSECS   equ     0xC00C                  ; 3 bytes: seconds, BCD, low byte first
CDIRTY  equ     0xC00F                  ; 1: the status line and cursor to redraw

CTEXT   equ     29                      ; text rows; the status line is row 29
PAIR0   equ     1 << 1                  ; light grey on black (PAL 1)
PAIR1   equ     2 << 1                  ; white on black: the banner
PAIR2   equ     3 << 1                  ; green on black: the self-test result
PAIR3   equ     4 << 1                  ; black on light grey: the status line

    IFNDEF CON_FRAMES
CON_FRAMES equ  100                     ; 2 s at 50 Hz after the chart appears
    ENDIF

conprep:
        ld      bc,MMU4_P               ; window 4: page 0x0FE (the map)
        ld      a,0xFE
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      b,MMU5_0                ; window 5: page 0x0FF (font, workspace)
        ld      a,0xFF
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      hl,font                 ; the font, from the ROM
        ld      de,CFONT
        ld      bc,256 * 8
        ldir
        ld      (CSP),sp                ; the map: spaces in pair 0, 4096
        ld      sp,CMAP + 0x2000        ; entries pushed from the top down
        ld      hl,' ' + (PAIR0 << 8)
        ld      b,0
.fill:
        dup     16
        push    hl
        edup
        djnz    .fill
        ld      sp,(CSP)
        xor     a
        ld      (DIM),a                 ; (the cursor shows; tmron sets it too)
        ld      (CROW),a
        ld      (CCOL),a
        ld      (CTOP),a
        ld      (CSECS),a
        ld      (CSECS + 1),a
        ld      (CSECS + 2),a
        ld      (CDIRTY),a
        call    kbinit                  ; the keyboards' variables, for the status line
        ld      a,CON_FRAMES
        ld      (CWAIT),a
        ld      hl,' ' + (PAIR0 << 8)
        ld      (CUNDER),hl
        call    constat                 ; the status line, and the cursor
        ; The start-up text
        ld      a,PAIR1
        ld      (CATTR),a
        ld      hl,cbanner              ; "retro-z80 " and SYSVER as major.minor
        call    cputs
        ld      a,SYSVER
        in      a,(SYSPAGE)
        push    af
        rrca
        rrca
        rrca
        rrca
        call    cputn
        ld      a,'.'
        call    cputc
        pop     af
        call    cputn
        call    cnl
        ld      a,PAIR0
        ld      (CATTR),a
        ld      hl,cz80                 ; "Z80 at " and the speed CPUSPEED gives
        call    cputs
        ld      a,CPUSPEED
        in      a,(SYSPAGE)
        bit     CPUSPEED_SPECTRUM_B,a
        ld      hl,cspeed_s
        jr      nz,.spd
        and     CPUSPEED_DIV_M          ; HL = cspeed + 5 x DIV
        ld      l,a
        add     a,a
        add     a,a
        add     a,l
        ld      l,a
        ld      h,0
        ld      bc,cspeed
        add     hl,bc
.spd:   call    cputs
        ld      hl,cmhz                 ; " MHz, N MB SRAM"
        call    cputs
        call    chipmb
        call    cputn
        ld      hl,csram
        call    cputs
        call    cnl
        ld      a,PAIR2
        ld      (CATTR),a
        ld      hl,stok                 ; "selftest ok, N MB", as sent to the PC
        call    cputs
        call    chipmb
        call    cputn
        ld      hl,mb
        call    cputs                   ; (its CR LF moves to the next line)
        ld      a,PAIR0
        ld      (CATTR),a
        ld      hl,hello                ; "hello" (and CR LF)
        call    cputs
        ld      hl,cprompt
    IFDEF CON_LINES
        call    cputs
        ; Test text (sim/Makefile, vtest bootscr): CON_LINES lines "line nn"
        ; (nn in decimal, from 01), which scroll the console
        ld      b,CON_LINES
        ld      c,0
.tl:    ld      hl,cline
        call    cputs
        ld      a,c
        add     a,1
        daa
        ld      c,a
        rrca
        rrca
        rrca
        rrca
        call    cputn
        ld      a,c
        call    cputn
        call    cnl
        djnz    .tl
        ret
cline:  db      "line ", 0
    ELSE
        jp      cputs
    ENDIF

; SYSCFG.CHIPMB in A (2 or 4)
chipmb: ld      a,SYSCFG
        in      a,(SYSPAGE)
        rrca
        rrca
        and     SYSCFG_CHIPMB_M >> SYSCFG_CHIPMB_B
        ret

; Print the zero-terminated string at HL (A, HL changed)
cputs:  ld      a,(hl)
        or      a
        ret     z
        call    cputc
        inc     hl
        jr      cputs

; Print A's low four bits as a hex digit (A changed)
cputn:  and     0x0F
        add     a,'0'
        cp      '9' + 1
        jr      c,cputc
        add     a,'A' - '9' - 1
        jr      cputc

; A new line (A changed)
cnl:    ld      a,13
        call    cputc
        ld      a,10
        ; on into cputc

; Print character A: 13 goes to column 0, 10 down a row (scrolling at the
; bottom), 8 back a column; any other code is drawn and the cursor moves on,
; to the next line after column 79. Only A and the flags change.
cputc:  push    bc
        push    de
        push    hl
        push    af
        ld      c,a
        call    curoff
        ld      a,c
        cp      13
        jr      z,.cr
        cp      10
        jr      z,.lf
        cp      8
        jr      z,.bs
        call    ccell
        ld      (hl),c                  ; the entry: code, then PAL
        inc     l
        ld      a,(CATTR)
        ld      (hl),a
        ld      a,(CCOL)
        inc     a
        cp      80
        jr      c,.col
        call    clf                     ; the end of the line: the next one
        xor     a
.col:   ld      (CCOL),a
        jr      .done
.cr:    xor     a
        ld      (CCOL),a
        jr      .done
.lf:    call    clf
        jr      .done
.bs:    ld      a,(CCOL)
        or      a
        jr      z,.done
        dec     a
        ld      (CCOL),a
        call    ccell                   ; rub it out
        ld      (hl),' '
        inc     l
        ld      (hl),PAIR0
.done:  call    curon
        pop     af
        pop     hl
        pop     de
        pop     bc
        ret

; Down a row; at the bottom, scroll the text up a row (A, B, HL changed)
clf:    ld      a,(CROW)
        inc     a
        cp      CTEXT
        jr      nc,cscroll
        ld      (CROW),a
        ret
; The map row shown at the top moves down one: the old status line becomes
; the last text row, cleared; the status line is drawn on the row below,
; then SCROLLY shows the new rows
cscroll:
        ld      a,(CTOP)
        inc     a
        and     31
        ld      (CTOP),a
        add     a,CTEXT - 1             ; the last text row
        and     31
        add     a,high CMAP
        ld      h,a
        ld      l,0
        ld      b,80
.clr:   ld      (hl),' '
        inc     l
        ld      (hl),PAIR0
        inc     l
        djnz    .clr
        call    cstatus
        ld      a,(CTOP)                ; SCROLLY = 8 x CTOP (at most 248)
        add     a,a
        add     a,a
        add     a,a
        ld      bc,L0_SCROLLY0_P
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ret

; HL = the map entry under the cursor (A changed)
ccell:  ld      a,(CTOP)
        ld      hl,CROW
        add     a,(hl)
        and     31
        add     a,high CMAP
        ld      h,a
        ld      a,(CCOL)
        add     a,a
        ld      l,a
        ret

; The cursor: the entry under it is kept in CUNDER and an underscore drawn
; over it while the background is bright (timer 0); while it is dim the
; entry shows. curoff puts the entry back (A, D, E, HL changed)
curon:  call    ccell
        ld      e,(hl)
        inc     l
        ld      d,(hl)
        ld      (CUNDER),de
        ld      a,(DIM)
        or      a
        ret     nz
        ld      (hl),PAIR0
        dec     l
        ld      (hl),'_'
        ret
curoff: call    ccell
        ld      de,(CUNDER)
        ld      (hl),e
        inc     l
        ld      (hl),d
        ret

; The status line and the cursor, drawn again (A, B, C, D, E, HL changed)
constat:
        call    cstatus
        call    curoff
        jr      curon

; The status line on the screen's row 29: text, then the seconds (CSECS,
; six BCD digits), then text, padded with spaces to column 79, in pair 3
; (A, B, C, D, E, HL changed)
cstatus:
        ld      a,(CTOP)
        add     a,CTEXT
        and     31
        add     a,high CMAP
        ld      d,a
        ld      e,0
        ld      c,80                    ; columns left
        ld      hl,cstat1               ; "... J1 ", joystick 1
        call    .str
        ld      a,(SJOY1)
        call    .joy
        ld      hl,cstat_j2             ; " J2 ", joystick 2
        call    .str
        ld      a,(SJOY2)
        call    .joy
        ld      hl,cstat_fe             ; "  FE ", port 0xFE
        call    .str
        ld      a,(SFE)
        call    .hex
        ld      hl,cstat_kb             ; "  KB ", the last PS/2 byte
        call    .str
        ld      a,(KLAST)
        call    .hex
        ld      hl,cstat_up             ; "  up ", the seconds
        call    .str
        ld      hl,CSECS + 2            ; the seconds, high digits first
        ld      b,3
.sec:   ld      a,(hl)
        rrca
        rrca
        rrca
        rrca
        call    .dig
        ld      a,(hl)
        call    .dig
        dec     hl
        djnz    .sec
        ld      hl,cstat2
        call    .str
.pad:   ld      a,' '                   ; the rest of the row
        call    .chr
        jr      nz,.pad
        ret
.hex:   push    af                      ; A as two hex digits
        rrca
        rrca
        rrca
        rrca
        call    .dig
        pop     af
.dig:   and     0x0F
        add     a,'0'
        cp      '9' + 1
        jr      c,.chr
        add     a,'A' - '9' - 1
.chr:   ld      (de),a                  ; one entry; Z when the row is full
        inc     e
        ld      a,PAIR3
        ld      (de),a
        inc     e
        dec     c
        ret
.str:   ld      a,(hl)
        or      a
        ret     z
        call    .chr
        inc     hl
        jr      .str
.joy:   ld      b,a                     ; joystick value A: a letter lit for each bit set
        ld      hl,joybits
.jl:    ld      a,(hl)
        or      a
        ret     z
        inc     hl
        and     b
        ld      a,(hl)
        inc     hl
        jr      nz,.jc
        ld      a,'.'
.jc:    call    .chr
        jr      .jl

; A byte from the serial link: printable codes (32-126, 128-255) are shown
; and sent back; CR is a new line (CR LF back); BS and DEL rub out the
; character before the cursor (BS, space, BS back); other codes are ignored
; (A, E changed)
conkey: cp      13
        jr      z,.cr
        cp      8
        jr      z,.bs
        cp      127
        jr      z,.bs
        cp      32
        ret     c
        call    cputc
        jp      putc
.cr:    call    cnl
        ld      a,13
        call    putc
        ld      a,10
        jp      putc
.bs:    ld      a,(CCOL)
        or      a
        ret     z
        ld      a,8
        call    cputc
        call    putc
        ld      a,' '
        call    putc
        ld      a,8
        jp      putc

; Called by the VBLANK handler every frame: CON_FRAMES frames after the
; interrupts start, L0 changes from the palette chart to the console, in
; the vertical blank (A, B, C, HL changed; DE kept)
convbl: ld      a,(CWAIT)
        or      a
        ret     z
        dec     a
        ld      (CWAIT),a
        ret     nz
        ld      bc,L0_CTRL0_P           ; L0 off
        out     (c),a
        push    de
        ld      hl,cpal                 ; PALETTE0 pairs 0-3: entries 16(p + 1) and 16(p + 1) + 1
        ld      d,16
.pb:    ld      bc,PALIDX0_P
        out     (c),d
        inc     b
        xor     a
        out     (c),a                   ; PALETTE0
        ld      b,PALDAT
        ld      e,6                     ; paper and ink: blue, green, red
.pd:    ld      a,(hl)
        out     (c),a
        inc     hl
        dec     e
        jr      nz,.pd
        ld      a,d
        add     a,16
        ld      d,a
        cp      5 * 16
        jr      nz,.pb
        pop     de
        ld      hl,c0regs
        call    setregs
        ld      bc,L0_CTRL0_P           ; on: 1 bit, tile map, 1x across
        ld      a,L_CTRL0_EN_M | L_CTRL0_MODE_M
        out     (c),a
        ret

; Timer 0's handler calls this on each half second: every second (on the
; dim-to-bright step) one more second; either way the status line and the
; cursor are to be drawn again (A, HL changed)
contick:
        ld      a,1
        ld      (CDIRTY),a
        ld      a,(DIM)
        or      a
        ret     nz
        ld      hl,CSECS
        ld      a,(hl)
        add     a,1
        daa
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        adc     a,0
        daa
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        adc     a,0
        daa
        ld      (hl),a
        ret

; L0's settings for the console: register, value
c0regs: db      L0_CTRL1, 1 << L_CTRL1_VSCALE_B                ; 2x down, PALOFS 0
        db      L0_CTRL2, 0
        db      L0_CTRL3, 2 << L_CTRL3_MAPW_B                  ; 128 x 32 entries
        db      L0_WINX0, 824 & 0xFF, L0_WINX1, 824 >> 8        ; 640 x 480 in the middle:
        db      L0_WINX2, 184, L0_WINX3, 0                      ; beam 184-824 ...
        db      L0_WINY0, 577 & 0xFF, L0_WINY1, 577 >> 8        ; ... x 97-577
        db      L0_WINY2, 97, L0_WINY3, 0
        db      L0_SCROLLX0, 0, L0_SCROLLX1, 0
        db      L0_MAPPT0, 0x00, L0_MAPPT1, 0xC0, L0_MAPPT2, 0x1F       ; 0x1FC000
        db      L0_PATPT0, 0x00, L0_PATPT1, 0xE0, L0_PATPT2, 0x1F       ; 0x1FE000
        db      0xFF

; The pairs: paper, then ink, each blue, green, red
cpal:   db      0x00, 0x00, 0x00,  0xD7, 0xD7, 0xD7     ; 0: light grey on black
        db      0x00, 0x00, 0x00,  0xFF, 0xFF, 0xFF     ; 1: white on black
        db      0x00, 0x00, 0x00,  0x00, 0xFF, 0x00     ; 2: green on black
        db      0xD7, 0xD7, 0xD7,  0x00, 0x00, 0x00     ; 3: black on light grey

cbanner: db     "retro-z80 ", 0
cz80:   db      "Z80 at ", 0
cspeed: db      "20", 0, 0, 0                           ; CPUSPEED.DIV 0-7, 5 bytes each
        db      "10", 0, 0, 0
        db      "6.67", 0
        db      "5", 0, 0, 0, 0
        db      "4", 0, 0, 0, 0
        db      "3.33", 0
        db      "2.86", 0
        db      "2.5", 0, 0
cspeed_s: db    "3.57", 0                               ; CPUSPEED.SPECTRUM
cmhz:   db      " MHz, ", 0
csram:  db      " MB SRAM", 0
cprompt: db     13, 10, "Type on the Spectrum keyboard, a PS/2 keyboard or the USB serial link.", 13, 10, 0
cstat1: db      " retro-z80 boot console  J1 ", 0
cstat_j2: db    " J2 ", 0
cstat_fe: db    "  FE ", 0
cstat_kb: db    "  KB ", 0
cstat_up: db    "  up ", 0
cstat2: db      " s", 0

        include "keys.asm"

font:   include "font.inc"
