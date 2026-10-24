; The boot ROM's tile-mode demo (spec 4, sections 4.5 and 5.2; ticket #14),
; included by boot.asm. Two seconds after the palette chart appears, the
; VBLANK handler turns layer L0 into a tile map over the whole screen and
; then scrolls it one source pixel right and down every frame.
;
;   Map      64 x 32 entries (CTRL3: MAPW 1, MAPH 0) at SRAM 0x000000
;            (window 2, page 0); 512 x 256 source pixels, so the map
;            repeats down the 288-line window and wraps round both ways
;   Tiles    4 bits per pixel, at SRAM 0x001000: 0 blank, 1 a letter F
;            (pixel 1) with a drop shadow (pixel 2), 2 a dot (pixel 3)
;   Layer    2 x 2, TRANSP (pixel 0 shows the background colour, which
;            still changes once a second), PALOFS 0
;   Blocks   of 4 x 4 tiles: the top-left 2 x 2 are the F four ways
;            (normal, XFLIP; YFLIP, XFLIP and YFLIP), the rest dots. Each
;            block's F has PAL 1-4 (red, green, blue, yellow) by diagonal;
;            the dots PAL 5 (grey)
;   Palette  PALETTE0 blocks 1-5, entries 1-3, written when the demo
;            starts (the chart is gone by then)
;
; tileprep writes the map and the patterns (a few ms, with the chart
; showing); tilevbl is called by the VBLANK handler every frame (A, B, C,
; HL changed; DE kept).
TMAP    equ     0x4000                  ; window 2: SRAM page 0, physical 0x000000
TPAT    equ     0x5000                  ; physical 0x001000
TWAIT   equ     0xC002                  ; frames until the demo starts
TSCROLL equ     0xC003                  ; 2 bytes: SCROLLX and SCROLLY

    IFNDEF TILE_FRAMES
TILE_FRAMES equ 100                     ; 2 s at 50 Hz
    ENDIF

tileprep:
        ld      hl,tiles
        ld      de,TPAT
        ld      bc,tiles_end - tiles
        ldir
        ld      hl,TMAP
        ld      c,0                     ; row
.row:   ld      b,0                     ; column
.col:   ld      a,b
        and     3
        cp      2
        jr      nc,.dot
        ld      a,c
        and     3
        cp      2
        jr      nc,.dot
        ld      (hl),1                  ; the F: TILE 1 ...
        inc     hl
        ld      a,b                     ; ... PAL 1 + (block column + block row) mod 4
        srl     a
        srl     a
        ld      e,a
        ld      a,c
        srl     a
        srl     a
        add     a,e
        and     3
        inc     a
        add     a,a                     ; PAL is bits 4-1 of the high byte
        ld      e,a
        bit     0,b
        jr      z,.nx
        set     5,e                     ; XFLIP on odd columns
.nx:    bit     0,c
        jr      z,.ny
        set     6,e                     ; YFLIP on odd rows
.ny:    ld      (hl),e
        inc     hl
        jr      .next
.dot:   ld      (hl),2                  ; the dot: TILE 2, PAL 5
        inc     hl
        ld      (hl),5 << 1
        inc     hl
.next:  inc     b
        ld      a,b
        cp      64
        jr      nz,.col
        inc     c
        ld      a,c
        cp      32
        jr      nz,.row
        ld      a,TILE_FRAMES
        ld      (TWAIT),a
        ld      hl,0
        ld      (TSCROLL),hl
        ret

tilevbl:
        ld      a,(TWAIT)
        or      a
        jr      z,.scroll
        dec     a
        ld      (TWAIT),a
        ret     nz
        ; Start: L0 off, the palette blocks, the tile settings, L0 on. In
        ; the vertical blank, so every write is in place by the first line
        ld      bc,L0_CTRL0_P
        xor     a
        out     (c),a
        push    de
        ld      hl,tpal
        ld      d,16 + 1                ; block 1, entry 1
.pb:    ld      bc,PALIDX0_P
        out     (c),d
        inc     b
        xor     a
        out     (c),a                   ; PALETTE0
        ld      b,PALDAT
        ld      e,9                     ; entries 1-3: blue, green, red
.pd:    ld      a,(hl)
        out     (c),a
        inc     hl
        dec     e
        jr      nz,.pd
        ld      a,d
        add     a,16
        ld      d,a
        cp      6 * 16 + 1
        jr      nz,.pb
        pop     de
        ld      hl,t0regs
        call    setregs
        ld      bc,L0_CTRL0_P           ; on: 4 bits, TRANSP, tile map, 2x across
        ld      a,L_CTRL0_EN_M | (2 << L_CTRL0_BPP_B) | L_CTRL0_TRANSP_M | L_CTRL0_MODE_M | (1 << L_CTRL0_HSCALE_B)
        out     (c),a
        ret
.scroll:
        ld      hl,(TSCROLL)            ; one source pixel right and down
        inc     hl
        ld      (TSCROLL),hl
        ld      bc,L0_SCROLLX0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b                       ; SCROLLY
        out     (c),l
        inc     b
        out     (c),h
        ret

; L0's settings for the demo: register, value
t0regs: db      L0_CTRL1, 1 << L_CTRL1_VSCALE_B                ; 2x down, PALOFS 0
        db      L0_CTRL2, 0
        db      L0_CTRL3, 1 << L_CTRL3_MAPW_B                  ; 64 x 32 entries
        db      L0_WINX0, 864 & 0xFF, L0_WINX1, 864 >> 8        ; the whole picture
        db      L0_WINX2, 144, L0_WINX3, 0
        db      L0_WINY0, 625 & 0xFF, L0_WINY1, 625 >> 8
        db      L0_WINY2, 49, L0_WINY3, 0
        db      L0_SCROLLX0, 0, L0_SCROLLX1, 0
        db      L0_SCROLLY0, 0, L0_SCROLLY1, 0
        db      L0_MAPPT0, 0x00, L0_MAPPT1, 0x00, L0_MAPPT2, 0x00       ; 0x000000
        db      L0_PATPT0, 0x00, L0_PATPT1, 0x10, L0_PATPT2, 0x00       ; 0x001000
        db      0xFF

; Palette blocks 1-5, entries 1-3 (the F, its shadow, the dot): blue, green, red
tpal:   db      0x40, 0x40, 0xFF,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 1 red
        db      0x40, 0xFF, 0x40,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 2 green
        db      0xFF, 0x80, 0x40,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 3 blue
        db      0x00, 0xFF, 0xFF,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 4 yellow
        db      0x40, 0x40, 0x40,  0x00, 0x00, 0x00,  0x40, 0x40, 0x40     ; 5 dark grey dot

; The patterns: 8 rows of 4 bytes, two pixels a byte, the left one high
tiles:  ds      32, 0                   ; 0: blank
        db      0x01, 0x11, 0x11, 0x10  ; 1: .FFFFFF.  F = 1, s = 2 (shadow)
        db      0x01, 0x12, 0x22, 0x22  ;    .FFsssss
        db      0x01, 0x12, 0x00, 0x00  ;    .FFs....
        db      0x01, 0x11, 0x11, 0x00  ;    .FFFFF..
        db      0x01, 0x12, 0x22, 0x20  ;    .FFssss.
        db      0x01, 0x12, 0x00, 0x00  ;    .FFs....
        db      0x01, 0x12, 0x00, 0x00  ;    .FFs....
        db      0x00, 0x22, 0x00, 0x00  ;    ..ss....
        ds      12, 0                   ; 2: a dot (pixel 3) in the middle
        db      0x00, 0x03, 0x30, 0x00
        db      0x00, 0x03, 0x30, 0x00
        ds      12, 0
tiles_end:
