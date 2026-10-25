; The console driver's core (spec 7, section 5.1; spec 16, section 7), in
; ROM page 0, included by boot.asm: 80 x 30 characters on layer L0 as a 1 bpp
; tile map of 128 x 32 entries in SRAM page 0x0FE, with the 8 x 8 font in
; page 0x0FF shown 2x tall.
;
; The core routines (k_...) run through ccall (calls.asm): the console page
; is mapped in a window borrowed for the call, IY points at its state (the
; page's base + 0xC0, in map row 0's hidden columns), interrupts are off.
; Arguments come in D and E, results go back in D and E; A, B, C, H, L and
; F may change. The map's base address (high byte) is CS_BASE. A map entry
; is the character code, then PAL x 2 (the colour pair + 1); map row r is at
; base + 256 r, so an entry's address is base + row, 2 x column.
;
; Text rows 0-29 show map rows CS_TOP to CS_TOP + 29 (wrapping at 32). The
; text scrolls by SCROLLY, a map row (8 source lines) at a time.

CTEXT   equ     30                      ; text rows

; PUTC: print E on the screen and the serial link, as CONMODE says
; (spec 16, section 7.5)
k_putc: bit     1,(iy+CS_MODE)
        jr      z,.scr
        ld      a,e
        out     (SERDATA_PORT),a
.scr:   bit     0,(iy+CS_MODE)
        ret     z
        call    curoff
        ld      a,e
        cp      32
        jr      nc,k_draw
        cp      13
        jr      z,.cr
        cp      10
        jr      z,clf
        cp      8
        jr      z,.bs
        cp      9
        jr      z,.tab
        cp      12
        jp      z,k_clsall
        ret                             ; other codes: nothing
.cr:    ld      (iy+CS_COL),0
        ret
.bs:    ld      a,(iy+CS_COL)
        or      a
        ret     z
        dec     (iy+CS_COL)
        ret
.tab:   ld      a,(iy+CS_COL)
        or      7
        inc     a
        cp      80
        jr      c,.tc
        ld      (iy+CS_COL),0
        jr      clf
.tc:    ld      (iy+CS_COL),a
        ret

; PUTRAW: draw the glyph for E, any code, on the screen only
k_putraw:
        call    curoff
        ; on into k_draw
; Draw E at the cursor and move it on, to the next line after column 79
k_draw: call    ccell
        ld      (hl),e
        inc     l
        ld      a,(iy+CS_ATTR)
        ld      (hl),a
        ld      a,(iy+CS_COL)
        inc     a
        cp      80
        jr      c,.col
        ld      (iy+CS_COL),0
        jr      clf
.col:   ld      (iy+CS_COL),a
        ret

; Down a row; at the bottom, scroll: the map row that shows at the top moves
; down one and the new bottom row is cleared
clf:    ld      a,(iy+CS_ROW)
        inc     a
        cp      CTEXT
        jr      nc,.scroll
        ld      (iy+CS_ROW),a
        ret
.scroll:
        ld      a,(iy+CS_TOP)
        inc     a
        and     31
        ld      (iy+CS_TOP),a
        add     a,CTEXT - 1
        ld      d,a
        call    k_clrrow
        ; on into setscy
; SCROLLY = 8 x CS_TOP (A, B, C changed)
setscy: ld      a,(iy+CS_TOP)
        add     a,a
        add     a,a
        add     a,a
        ld      bc,L0_SCROLLY0_P
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ret

; Clear map row D (any number: taken modulo 32), columns 0-79
k_clrrow:
        ld      a,d
        and     31
        add     a,(iy+CS_BASE)
        ld      h,a
        ld      l,0
        ld      a,PAIR0
        ld      b,80
.clr:   ld      (hl),' '
        inc     l
        ld      (hl),a
        inc     l
        djnz    .clr
        ret

; The cursor to the top left of an unscrolled screen (CLS's last step)
k_home: call    curoff
        xor     a
        ld      (iy+CS_ROW),a
        ld      (iy+CS_COL),a
        ld      (iy+CS_TOP),a
        jr      setscy

; Code 12 through PUTC: the whole map cleared at once (interrupts stay off
; for about 5 ms; CLS, RST 28h function 9, clears a row at a time)
k_clsall:
        ld      d,31
.row:   push    de
        call    k_clrrow
        pop     de
        dec     d
        jp      p,.row
        jr      k_home

; SETPOS: D = row, E = column, cut to the screen
k_setpos:
        call    curoff
        ld      a,d
        cp      CTEXT
        jr      c,.r
        ld      a,CTEXT - 1
.r:     ld      (iy+CS_ROW),a
        ld      a,e
        cp      80
        jr      c,.c
        ld      a,79
.c:     ld      (iy+CS_COL),a
        ret

; GETPOS: D = row, E = column
k_getpos:
        ld      d,(iy+CS_ROW)
        ld      e,(iy+CS_COL)
        ret

; SETPAIR: E = the colour pair, 0-14 (more is cut to 14)
k_setpair:
        ld      a,e
        cp      15
        jr      c,.p
        ld      a,14
.p:     inc     a
        add     a,a
        ld      (iy+CS_ATTR),a
        ret

; CONMODE: E = the new mode, or 0x80 to read it; E = the old mode
k_conmode:
        ld      a,(iy+CS_MODE)
        bit     7,e
        jr      nz,.rd
        ld      (iy+CS_MODE),e
.rd:    ld      e,a
        ret

; One step of GETC: blink the cursor (shown while TIME bit 18 is 0: about
; a quarter of a second on, a quarter off) and look for a key. E = the key,
; with the cursor taken away, or 0
k_gstep:
        call    k_poll
        ld      a,e
        or      a
        jr      nz,curoff
        bit     0,(iy+CS_MODE)          ; no screen: no cursor
        ret     z
        call    ktime
        bit     2,h
        jr      nz,curoff
        ; on into curon
; Draw the cursor (an underscore in pair 0) over the entry at the cursor,
; keeping the entry in CS_UNDER (A, H, L changed)
curon:  bit     0,(iy+CS_CUR)
        ret     nz
        call    ccell
        ld      a,(hl)
        ld      (iy+CS_UNDER),a
        ld      (hl),'_'
        inc     l
        ld      a,(hl)
        ld      (iy+CS_UNDER+1),a
        ld      (hl),PAIR0
        ld      (iy+CS_CUR),1
        ret
; Take the cursor away: the entry under it back (A, H, L changed)
curoff: bit     0,(iy+CS_CUR)
        ret     z
        call    ccell
        ld      a,(iy+CS_UNDER)
        ld      (hl),a
        inc     l
        ld      a,(iy+CS_UNDER+1)
        ld      (hl),a
        ld      (iy+CS_CUR),0
        ret

; HL = the map entry at the cursor (A changed)
ccell:  ld      a,(iy+CS_TOP)
        add     a,(iy+CS_ROW)
        and     31
        add     a,(iy+CS_BASE)
        ld      h,a
        ld      a,(iy+CS_COL)
        add     a,a
        ld      l,a
        ret

; The last line typed, byte D: HL = its place (rows 1-4, columns 96-127)
k_hadr: ld      a,d
        rlca
        rlca
        and     3
        inc     a
        add     a,(iy+CS_BASE)
        ld      h,a
        ld      a,d
        and     63
        or      0xC0
        ld      l,a
        ret
; Keep byte E of the last line at D
k_hput: call    k_hadr
        ld      (hl),e
        ret
; E = byte D of the last line
k_hget: call    k_hadr
        ld      e,(hl)
        ret

; HL = TIME bits 23-8 (256 us steps). Reading TIME0 captures (spec 9).
; A, B, C changed
ktime:  ld      bc,TIME0_P
        in      a,(c)
        inc     b
        in      l,(c)
        inc     b
        in      h,(c)
        ret
