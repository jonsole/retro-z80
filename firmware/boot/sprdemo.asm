; The sprite demo (spec 5; ticket #31), in ROM page 3, included by boot.asm
; and run with page 3 in window 2. The monitor runs it for F1 on an empty
; command line (a PS/2 keyboard's F1, ESC O P over the serial link, or GRAPH
; on the membrane: CAPS SHIFT + 9, or the Next's GRAPH key); BREAK (or Esc)
; goes back to the monitor.
;
; Eight Amiga "Boing" balls, red and white checkered spheres, bounce with
; gravity over ticket #14's tile scroller (the F's, scrolling diagonally):
;
;   Images   drawn into SRAM once, at the start, by code: each checker
;            square's colour index comes from its longitude band and its
;            latitude row, so a ball spins by palette cycling (rotating its
;            band colours in SPRPALETTE each frame), never by redrawing.
;            8 bpp: 48 x 48, 4 shades (lit from the top left), 16 steps a
;            band pair; 4 bpp: 48 x 48 and 32 x 32, 6 steps a band pair; 2
;            bpp: 32 x 32 and 16 x 16, three colours (red, white, pink)
;   Balls    sprites 0-7: 8, 4, 4, 4, 4, 2, 2 and 8 bpp, shown 32-96 pixels
;            wide (SPRxSTEP: 1x to 3x); each 4 bpp and 2 bpp ball has a
;            16-colour block of its own (PAL), so it spins at its own rate
;            and way; the two 8 bpp balls share entries 128-255
;   Depth    sprites 0, 2, 4 and 6 in front of L0 (DEPTH 0), 1, 3, 5 and 7
;            behind it (DEPTH 1): the F's pass over them
;   Bounce   a ball that lands is squashed (wider and lower, SPRxSTEP) for
;            7 frames; sprite 4 zooms in and out all the time instead
;   Flash    a collision between balls (SPRCOLL0, new this frame) flashes
;            the background (BGCOLOR, the border) for 4 frames
;
; No copper yet: the VBLANK interrupt (IM 2, the demo's own table) writes
; every sprite's registers each frame, CTL last, through the register page,
; with the spinning palette entries and the scroll; the main loop moves the
; balls for the next frame and polls the keys.
;
; SRAM: pages 0x0FC and 0x0FD (spec 16, section 5.3: kept for the ROM) in
; windows 6 and 7, given back on the way out; the register page in window
; 5. On the way out the console is rebuilt (conl0) and the ROM's interrupt
; table set again.

BD_MAP  equ     0xC000                  ; window 6: SRAM page 0x0FC (0x1F8000): the tile map
BD_PAT  equ     0xD000                  ; 0x1F9000: the tile patterns
BD_STR8 equ     0xD100                  ; the 8 bpp balls' colours: 4 shades x 48 entries
BD_BND  equ     0xD400                  ; 65: a row's longitude boundaries (+ 128)
BD_SHAD equ     0xD500                  ; 128: the sprites' 16 registers each, for the next frame
BD_BALL equ     0xD580                  ; 8 x 16: the balls
BD_VAR  equ     0xD600                  ; variables
BD_IMG  equ     0xE000                  ; window 7: SRAM page 0x0FD (0x1FA000): the images
BD_REGS equ     0xA000                  ; window 5: the register page
BD_SPAL equ     BD_REGS + REGS_SPRPALETTE

; Images: physical addresses (window 7 is 0x1FA000)
IMG8    equ     0x1FA000                ; 48 x 48, 8 bpp: 2304 bytes
IMG4L   equ     0x1FA900                ; 48 x 48, 4 bpp: 1152
IMG4S   equ     0x1FAD80                ; 32 x 32, 4 bpp: 512
IMG2L   equ     0x1FAF80                ; 32 x 32, 2 bpp: 256
IMG2S   equ     0x1FB080                ; 16 x 16, 2 bpp: 64
W7      equ     0xE000 - 0x1FA000       ; physical to window 7

; Variables
BV_FRAME equ    BD_VAR + 0              ; counted by the VBLANK handler
BV_SEEN  equ    BD_VAR + 1              ; ... the last frame the main loop saw
BV_SCRL  equ    BD_VAR + 2              ; 2: SCROLLX and SCROLLY
BV_FLASH equ    BD_VAR + 4              ; frames of flash left
BV_PREV  equ    BD_VAR + 5              ; SPRCOLL0 in the last frame
BV_D     equ    BD_VAR + 8              ; drawing: the diameter
BV_TYPE  equ    BD_VAR + 9              ; ... 0 8 bpp, 1 4 bpp, 2 2 bpp
BV_Y     equ    BD_VAR + 10             ; ... the row
BV_YC    equ    BD_VAR + 11             ; ... its centre in half pixels, + 128
BV_D2    equ    BD_VAR + 12             ; 2: D x D
BV_R2    equ    BD_VAR + 14             ; 2: D x D - yc x yc
BV_W     equ    BD_VAR + 16             ; the row's half width, in half pixels
BV_LAT   equ    BD_VAR + 17             ; the row's latitude, 0-7
BV_H     equ    BD_VAR + 18             ; the highlight's offset (8 bpp)
BV_SHY   equ    BD_VAR + 20             ; 2: (yc + h) squared
BV_THR   equ    BD_VAR + 22             ; 6: the three shade thresholds
BV_LATB  equ    BD_VAR + 28             ; 7: the latitude boundaries, + 128
BV_X     equ    BD_VAR + 35             ; pixels left in the row
BV_XC    equ    BD_VAR + 36             ; the pixel's centre in half pixels (signed)
BV_XSQ   equ    BD_VAR + 38             ; 2: xc squared
BV_ACC   equ    BD_VAR + 40             ; pixels being packed into a byte
BV_NPK   equ    BD_VAR + 41             ; ... pixels still to come in it
BV_F     equ    BD_VAR + 42             ; the longitude step, 0-63
BV_DST   equ    BD_VAR + 44             ; 2: where the next byte goes
BV_PTR   equ    BD_VAR + 46             ; 2: the shadow register being written

GRAV    equ     6                       ; gravity: 6/16 pixel per frame per frame
FLASHN  equ     4                       ; frames of flash

; ================================================================ start
sprdemo:
        di
        ld      hl,T_DBUF               ; windows 5-7's pages kept (12 bytes), in the monitor's temporaries
        ld      bc,MMU5_0_P
.sv:    in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7_1 + 1
        jr      nz,.sv
        ld      b,MMU5W_0
.svw:   in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7W_1 + 1
        jr      nz,.svw
        ld      hl,bdmap                ; the register page and pages 0x0FC-0x0FD
        ld      bc,MMU5_0_P
.map:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7_1 + 1
        jr      nz,.map
        call    bdtiles                 ; the tile map and patterns
        call    bdstrips                ; the 8 bpp colours
        ld      hl,imgs                 ; the images
.img:   ld      a,(hl)
        or      a
        jr      z,.imgd
        inc     hl
        ld      c,(hl)
        inc     hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        call    bdraw
        pop     hl
        jr      .img
.imgd:  call    bdinit                  ; the balls, and the first frame's registers
        ; ---- L0: the tile scroller
        ld      bc,L0_CTRL0_P
        xor     a
        out     (c),a
        ld      hl,bdtpal               ; PALETTE0 blocks 1-5, entries 1-3
        ld      d,16 + 1
.pb:    ld      bc,PALIDX0_P
        out     (c),d
        inc     b
        xor     a
        out     (c),a
        ld      b,PALDAT
        ld      e,9
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
        ld      hl,bdl0
        ld      c,CUSTPAGE
.reg:   ld      b,(hl)
        inc     hl
        ld      a,b
        cp      0xFF
        jr      z,.regd
        ld      a,(hl)
        inc     hl
        out     (c),a
        jr      .reg
.regd:  ld      bc,L0_CTRL0_P           ; on: 4 bits, TRANSP, tile map, 2x across
        ld      a,L_CTRL0_EN_M | (2 << L_CTRL0_BPP_B) | L_CTRL0_TRANSP_M | L_CTRL0_MODE_M | (1 << L_CTRL0_HSCALE_B)
        out     (c),a
        ld      hl,bdback
        call    setbg
        ld      bc,DMACON_P             ; the sprites' fetch on
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BPLEN_M | DMACON_SPREN_M
        out     (c),a
        ; ---- VBLANK on IM 2, through the demo's table
        ld      a,high bdivt
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low bdivt
        out     (c),a
        ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a
        ld      bc,VIDINTEN_P
        out     (c),a
        ld      bc,INTENA0_P + (INTR_VBLANK << 8)
        ld      a,INTENA_SETCLR_M | (1 << INTB_VBLANK)
        out     (c),a
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a
        ei
        ; ---- each frame: the balls for the next one, and the keys
.loop:  halt
        ld      a,(BV_FRAME)
        ld      hl,BV_SEEN
        cp      (hl)
        jr      z,.loop
        ld      (hl),a
        call    bdmove
        rst     20h                     ; POLLC
        jr      z,.loop
        cp      27                      ; BREAK or Esc
        jr      nz,.loop
        ; ---- back to the monitor
        di
        ld      bc,INTENA0_P + (INTR_VBLANK << 8)
        ld      a,1 << INTB_VBLANK
        out     (c),a
        ld      bc,INTCON_P
        xor     a
        out     (c),a
        ld      bc,VIDINTEN_P
        out     (c),a
        ld      bc,VIDSTAT_P
        ld      a,0xFF
        out     (c),a
        ld      a,high ivt              ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low ivt
        out     (c),a
        call    conl0                   ; the console on L0 (the sprites' fetch off)
        ld      hl,T_DBUF               ; windows 5-7 as they were
        ld      bc,MMU5_0_P
.rs:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7_1 + 1
        jr      nz,.rs
        ld      b,MMU5W_0
.rsw:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7W_1 + 1
        jr      nz,.rsw
        ret

bdmap:  dw      PG_REGS, 0x0FC, 0x0FD   ; windows 5, 6, 7
bdback: db      0x50, 0x28, 0x28        ; the background: dark blue-grey
bdfl:   db      0xFF, 0xC0, 0xA0        ; ... flashing: light blue

; The images: diameter, type, address in window 7; 0 ends
imgs:   db      48, 0
        dw      IMG8 + W7
        db      48, 1
        dw      IMG4L + W7
        db      32, 1
        dw      IMG4S + W7
        db      32, 2
        dw      IMG2L + W7
        db      16, 2
        dw      IMG2S + W7
        db      0

; ================================================================ VBLANK
bdvbl:  push    af
        push    bc
        push    de
        push    hl
        ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a                   ; the request ends
        ; ---- the 8 bpp balls' entries 128-255 at ball 0's phase t: per
        ; shade, latitude 0 from strip entry t, latitude 1 from t + 8
        ld      a,(BD_BALL + 8)
        ld      l,a
        ld      h,0
        ld      e,l
        ld      d,h
        add     hl,hl
        add     hl,de
        ld      de,BD_STR8
        add     hl,de
        ld      de,BD_SPAL + 3 * 128
        ld      a,4
.s8:    push    hl
        ld      bc,48
        ldir
        pop     hl
        push    hl
        ld      bc,24
        add     hl,bc
        ld      bc,48
        ldir
        pop     hl
        ld      bc,144
        add     hl,bc
        dec     a
        jr      nz,.s8
        ; ---- the 4 bpp and 2 bpp balls: entries 1-12 or 1-3 of their block
        ld      hl,btab + 3             ; the balls' CTL
        ld      de,BD_BALL + 8          ; ... and phase
        ld      a,8
.sb:    push    af
        push    hl
        push    de
        ld      a,(hl)
        and     3
        cp      2
        jr      z,.sn                   ; 8 bpp: done above
        ld      c,a                     ; BPP: 0 2 bpp, 1 4 bpp
        ld      a,(hl)                  ; the block: PAL x 16 + 1, x 3
        and     0xF0
        inc     a
        push    de
        ld      e,a
        ld      d,0
        ld      h,d
        ld      l,e
        add     hl,hl
        add     hl,de
        ld      de,BD_SPAL
        add     hl,de
        ex      (sp),hl                 ; the entry's address; HL = phase's address
        ld      a,(hl)
        ld      l,a
        ld      h,0
        ld      e,l
        ld      d,h
        add     hl,hl
        add     hl,de                   ; 3 x phase
        pop     de
        ld      a,c
        dec     a
        jr      z,.s4
        ld      bc,bdstr2
        add     hl,bc
        ld      bc,9
        ldir
        jr      .sn
.s4:    ld      bc,bdstr4
        add     hl,bc
        push    hl
        ld      bc,18
        ldir
        pop     hl
        ld      bc,9
        add     hl,bc
        ld      bc,18
        ldir
.sn:    pop     de
        pop     hl
        ld      bc,BT_SIZE
        add     hl,bc
        ld      a,e
        add     a,16
        ld      e,a
        pop     af
        dec     a
        jr      nz,.sb
        ; ---- every sprite's registers: STEP, then PT, H, V and CTL, last
        ld      hl,BD_SHAD
        ld      de,BD_REGS + REGS_CUSTOM + SPR0
        ld      a,8
.spr:   push    hl
        push    de
        ld      bc,12
        add     hl,bc
        ex      de,hl
        add     hl,bc
        ex      de,hl
        ldi
        ldi
        ldi
        ldi
        pop     de
        pop     hl
        ld      bc,12
        ldir
        ld      bc,4
        add     hl,bc
        ex      de,hl
        add     hl,bc
        ex      de,hl
        dec     a
        jr      nz,.spr
        ; ---- the scroll: one source pixel right and down
        ld      hl,(BV_SCRL)
        inc     hl
        ld      (BV_SCRL),hl
        ld      bc,L0_SCROLLX0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        out     (c),l
        inc     b
        out     (c),h
        ; ---- a new collision between balls flashes the background
        ld      bc,SPRCOLL0_P
        in      a,(c)
        out     (c),a                   ; cleared
        ld      hl,BV_PREV
        ld      b,(hl)
        ld      (hl),a
        or      a
        jr      z,.nf
        inc     b
        dec     b
        jr      nz,.nf                  ; already touching
        ld      a,FLASHN
        ld      (BV_FLASH),a
.nf:    ld      hl,BV_FLASH
        ld      a,(hl)
        or      a
        jr      z,.bg
        dec     (hl)
        ld      hl,bdfl
        jr      .bg1
.bg:    ld      hl,bdback
.bg1:   call    setbg
        ld      hl,BV_FRAME
        inc     (hl)
        pop     hl
        pop     de
        pop     bc
        pop     af
        ei
        reti

; Any other source: the ROM's handler turns it off
bdspur: jp      ivhand

; ================================================================ the balls
; The balls in ROM, BT_SIZE bytes each:
;   +0 SPRxPT (3)  +3 SPRxCTL  +4 the squash or zoom table (2)  +6 x at the
;   start  +8 dx  +9 bounce speed (2, 1/16 pixel a frame)  +11 the lowest y
;   (2, 1/16 pixel: the floor less the height)  +13 the highest x (2)
;   +15 frames a spin step  +16 the step (1, or period - 1 backwards)
;   +17 the period  +18 bit 7: zooms (else squashes)  +19 y at the start
; In RAM, 16 bytes each: +0 x (2, beam pixel)  +2 y (2, beam line x 16)
;   +4 vy (2)  +6 dx  +7 squash left  +8 phase  +9 frames to the next step
;   +10 the zoom count
BT_SIZE equ     20

; One ball: image, DEPTH, PAL, BPP, its squash or zoom table, display
; size, x, dx, bounce speed, spin (frames a step, step, period), zoom, y
        MACRO   BALL pt, depth, pal, bc, tab, wb, x0, dx, vb, rate, dir, period, zoom, y0
        db      low (pt), high (pt), (pt) >> 16
        db      (bc) | ((depth) << 2) | ((pal) << 4)
        dw      tab
        dw      x0
        db      dx
        dw      vb
        dw      (625 - (wb)) * 16
        dw      864 - (wb)
        db      rate, dir, period
        db      (zoom) << 7
        db      y0
        ENDM

btab:   BALL    IMG8,  0, 0, 2, bsq0, 96, 200,  2, 256, 1, 1,  16, 0, 60
        BALL    IMG4L, 1, 1, 1, bsq1, 48, 500, -3, 208, 2, 1,  6,  0, 200
        BALL    IMG4L, 0, 2, 1, bsq2, 72, 650, -1, 240, 3, 5,  6,  0, 120
        BALL    IMG4S, 1, 3, 1, bsq3, 32, 300,  3, 192, 2, 5,  6,  0, 250
        BALL    IMG4S, 0, 4, 1, bsq4, 64, 400,  1, 224, 2, 1,  6,  1, 100
        BALL    IMG2L, 1, 5, 0, bsq5, 32, 160,  2, 176, 6, 1,  3,  0, 250
        BALL    IMG2S, 0, 6, 0, bsq6, 48, 700, -2, 200, 5, 2,  3,  0, 150
        BALL    IMG8,  1, 0, 2, bsq7, 60, 600, -2, 224, 1, 1,  16, 0, 80

; The squash tables, 8 levels of 8 bytes: W, H, XSTEP, YSTEP, x offset, y
; offset (wider and lower, the bottom kept); the zoom tables the same, both
; ways larger. STEP = source x 2048 / size, rounded down, so the image's
; line length in words is the same at every level
        MACRO   SQTAB src, wb, zoom
sqk = 0
        DUP     8
        IF      zoom
sqw = (wb) * (64 + 6 * sqk) / 64
sqh = sqw
        ELSE
sqw = (wb) * (64 + 3 * sqk) / 64
sqh = (wb) * (64 - 3 * sqk) / 64
        ENDIF
        db      sqw, sqh
        dw      (src) * 2048 / sqw, (src) * 2048 / sqh
        db      low (((wb) - sqw) / 2), low ((wb) - sqh)
sqk = sqk + 1
        EDUP
        ENDM

bsq0:   SQTAB   48, 96, 0
bsq1:   SQTAB   48, 48, 0
bsq2:   SQTAB   48, 72, 0
bsq3:   SQTAB   32, 32, 0
bsq4:   SQTAB   32, 64, 1
bsq5:   SQTAB   32, 32, 0
bsq6:   SQTAB   16, 48, 0
bsq7:   SQTAB   48, 60, 0

; The balls at the start, and their first frame's registers
bdinit: ld      ix,BD_BALL
        ld      iy,btab
        ld      b,8
.b:     ld      a,(iy+6)
        ld      (ix+0),a
        ld      a,(iy+7)
        ld      (ix+1),a
        ld      l,(iy+19)               ; y x 16
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      (ix+2),l
        ld      (ix+3),h
        xor     a
        ld      (ix+4),a
        ld      (ix+5),a
        ld      (ix+7),a
        ld      (ix+8),a
        ld      (ix+10),a
        ld      a,(iy+8)
        ld      (ix+6),a
        ld      a,1
        ld      (ix+9),a
        ld      de,16
        add     ix,de
        ld      de,BT_SIZE
        add     iy,de
        djnz    .b
        xor     a
        ld      (BV_FRAME),a
        ld      (BV_SEEN),a
        ld      (BV_FLASH),a
        ld      (BV_PREV),a
        ld      h,a
        ld      l,a
        ld      (BV_SCRL),hl
        ; on into bdmove: the first frame's registers

; Move the balls one frame and write their registers for the next frame
bdmove: ld      ix,BD_BALL
        ld      iy,btab
        ld      hl,BD_SHAD
        ld      b,8
.b:     push    bc
        push    hl
        ; ---- down: vy += gravity, y += vy; on the floor, bounce
        ld      l,(ix+4)
        ld      h,(ix+5)
        ld      de,GRAV
        add     hl,de
        ld      (ix+4),l
        ld      (ix+5),h
        ex      de,hl
        ld      l,(ix+2)
        ld      h,(ix+3)
        add     hl,de
        ld      e,(iy+11)
        ld      d,(iy+12)
        or      a
        sbc     hl,de
        add     hl,de
        jr      c,.air
        ex      de,hl                   ; on the floor: up at the bounce speed
        xor     a
        sub     (iy+9)
        ld      (ix+4),a
        sbc     a,a
        sub     (iy+10)
        ld      (ix+5),a
        bit     7,(iy+18)
        jr      nz,.air
        ld      (ix+7),7                ; squashed for 7 frames
.air:   ld      (ix+2),l
        ld      (ix+3),h
        ; ---- across: bounce off the sides
        ld      l,(ix+0)
        ld      h,(ix+1)
        ld      a,(ix+6)
        ld      e,a
        rla
        sbc     a,a
        ld      d,a
        add     hl,de
        ld      de,144
        or      a
        sbc     hl,de
        add     hl,de
        jr      c,.flip
        ld      e,(iy+13)
        ld      d,(iy+14)
        ex      de,hl
        or      a
        sbc     hl,de
        add     hl,de
        ex      de,hl
        jr      nc,.xok                 ; x <= the highest
        ex      de,hl                   ; the highest
        jr      .flp
.flip:  ld      hl,144                  ; back to the side, and the other way
.flp:   xor     a
        sub     (ix+6)
        ld      (ix+6),a
.xok:   ld      (ix+0),l
        ld      (ix+1),h
        ; ---- the level: squash left, or the zoom's triangle wave
        bit     7,(iy+18)
        jr      z,.sq
        inc     (ix+10)
        ld      a,(ix+10)
        rrca
        rrca
        rrca
        and     15
        cp      8
        jr      c,.lv
        cpl
        and     7
        jr      .lv
.sq:    ld      a,(ix+7)
        or      a
        jr      z,.lv
        dec     (ix+7)
.lv:    add     a,a                     ; the level's entry
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        ld      l,(iy+4)
        ld      h,(iy+5)
        add     hl,de
        push    hl
        ; ---- the spin
        dec     (ix+9)
        jr      nz,.sp
        ld      a,(iy+15)
        ld      (ix+9),a
        ld      a,(ix+8)
        add     a,(iy+16)
        cp      (iy+17)
        jr      c,.ph
        sub     (iy+17)
.ph:    ld      (ix+8),a
.sp:    pop     de                      ; DE = the level's entry
        pop     hl                      ; HL = the shadow registers
        push    hl
        ld      a,(iy+0)                ; PT
        ld      (hl),a
        inc     hl
        ld      a,(iy+1)
        ld      (hl),a
        inc     hl
        ld      a,(iy+2)
        ld      (hl),a
        inc     hl
        ld      (BV_PTR),hl
        ld      hl,6                    ; HSTART = x + x offset, HSTOP = HSTART + W
        add     hl,de
        ld      a,(hl)
        ld      c,a
        rla
        sbc     a,a
        ld      b,a
        ld      l,(ix+0)
        ld      h,(ix+1)
        add     hl,bc
        ld      a,(de)
        call    bdpair
        ld      hl,7                    ; VSTART = y / 16 + y offset, VSTOP = VSTART + H
        add     hl,de
        ld      a,(hl)
        ld      c,a
        rla
        sbc     a,a
        ld      b,a
        ld      l,(ix+2)
        ld      h,(ix+3)
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        add     hl,bc
        inc     de
        ld      a,(de)
        dec     de
        call    bdpair
        ld      hl,(BV_PTR)
        ld      a,(iy+3)                ; CTL
        ld      (hl),a
        inc     hl
        ex      de,hl                   ; STEP: XSTEP, YSTEP
        ld      bc,2
        add     hl,bc
        ld      bc,4
        ldir
        pop     hl
        ld      bc,16
        add     hl,bc
        ld      bc,16
        add     ix,bc
        ld      bc,BT_SIZE
        add     iy,bc
        pop     bc
        dec     b
        jp      nz,.b
        ret
; HL = start, A = size: start and start + size, 2 bytes each, at BV_PTR,
; which moves on by 4 (A, BC changed)
bdpair: push    de
        ex      de,hl
        ld      hl,(BV_PTR)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ex      de,hl
        ld      c,a
        ld      b,0
        add     hl,bc
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (BV_PTR),hl
        pop     de
        ret

; ================================================================ drawing
; One ball's image: A = the diameter D (even, up to 48), C = the type (0 8
; bpp, 1 4 bpp, 2 2 bpp), DE = where. Rows of D pixels, packed, the first
; pixel in the high bits. Half-pixel units: the centre of pixel x is at
; xc = 2x + 1 - D, the edge at +-D. Inside if xc^2 + yc^2 < D^2. The
; latitude (0-7) counts the boundaries sin(-90 + 22.5j), j = 1-7, below
; yc / D; the longitude step f (0-63) counts the boundaries
; w sin(-90 + 2.8125j), j = 1-63, below xc, w the row's half width. Pixel
;   8 bpp  128 + 32 shade + 16 (lat & 1) + (f & 15)
;   4 bpp  1 + 6 (lat & 1) + (3 (f & 15)) / 8
;   2 bpp  1 + (f / 8 + lat) mod 3
; and the shade (8 bpp) counts the thresholds 6/16, 15/16 and 26/16 x D^2
; below the squared distance from the highlight at (-0.35 D, -0.35 D).
bdraw:  ld      (BV_D),a
        ld      a,c
        ld      (BV_TYPE),a
        ld      (BV_DST),de
        ld      a,(BV_D)
        ld      e,a
        call    mul8
        ld      (BV_D2),hl
        ld      a,(BV_D)                ; h = 90 D / 256
        ld      e,90
        call    mul8
        ld      a,h
        ld      (BV_H),a
        ld      hl,(BV_D2)              ; the thresholds: D^2 / 16 x 6, 15, 26
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        ld      ix,BV_THR
        ld      iy,bdthk
        ld      b,3
.th:    push    hl
        push    bc
        ld      a,(iy+0)
        ld      b,h
        ld      c,l
        ld      hl,0
.tm:    add     hl,bc
        dec     a
        jr      nz,.tm
        ld      (ix+0),l
        ld      (ix+1),h
        inc     ix
        inc     ix
        inc     iy
        pop     bc
        pop     hl
        djnz    .th
        ld      ix,BV_LATB              ; the latitude boundaries: (D x sin) / 256, + 128
        ld      iy,bdslat
        ld      b,7
.lb:    push    bc
        ld      a,(iy+0)
        ld      e,a
        ld      a,(BV_D)
        call    mul8                    ; D x |sin|
        ld      a,(iy+1)                ; the sign
        or      a
        ld      a,h
        jr      z,.lp
        ld      a,l                     ; negative: -ceil(p / 256)
        or      a
        ld      a,h
        jr      z,.ln
        inc     a
.ln:    neg
.lp:    add     a,128
        ld      (ix+0),a
        inc     ix
        inc     iy
        inc     iy
        pop     bc
        djnz    .lb
        xor     a
        ld      (BV_Y),a
.row:   ld      a,(BV_Y)                ; yc = 2y + 1 - D
        add     a,a
        inc     a
        ld      hl,BV_D
        sub     (hl)
        ld      c,a                     ; C = yc
        add     a,128
        ld      (BV_YC),a
        ld      a,c
        call    sq8
        ex      de,hl
        ld      hl,(BV_D2)
        or      a
        sbc     hl,de
        ld      (BV_R2),hl
        call    isqrt
        ld      (BV_W),a
        ld      hl,BV_LATB              ; the latitude
        ld      a,(BV_YC)
        ld      b,7
        ld      c,0
.lt:    cp      (hl)
        jr      z,.lt1
        jr      c,.lt1
        inc     c
.lt1:   inc     hl
        djnz    .lt
        ld      a,c
        ld      (BV_LAT),a
        ld      hl,BD_BND + 1           ; the longitude boundaries
        ld      iy,bdslon
        ld      b,31
.bn:    push    bc
        push    hl
        ld      a,(BV_W)
        ld      e,(iy+0)
        call    mul8
        ld      c,h                     ; m = (w x cos) / 256
        pop     hl
        ld      a,128
        sub     c
        ld      (hl),a                  ; bnd[j] = 128 - m
        push    hl
        ld      a,l                     ; bnd[64 - j] = 128 + m: offset 64 - j
        cpl
        add     a,65
        ld      l,a
        ld      a,128
        add     a,c
        ld      (hl),a
        pop     hl
        inc     hl
        inc     iy
        pop     bc
        djnz    .bn
        ld      (hl),128                ; bnd[32]
        ld      a,255
        ld      (BD_BND + 64),a         ; never passed
        ld      a,(BV_TYPE)             ; 8 bpp: (yc + h)^2
        or      a
        jr      nz,.nsh
        ld      a,(BV_YC)
        sub     128
        ld      hl,BV_H
        add     a,(hl)
        call    sq8
        ld      (BV_SHY),hl
.nsh:
        ; ---- the row's pixels
        ld      a,(BV_D)
        ld      (BV_X),a
        ld      c,a                     ; xc = 1 - D
        ld      a,1
        sub     c
        ld      (BV_XC),a
        call    sq8
        ld      (BV_XSQ),hl
        xor     a
        ld      (BV_F),a
        ld      (BV_ACC),a
        ld      a,(BV_TYPE)             ; pixels a byte
        or      a
        ld      a,1
        jr      z,.np
        ld      a,(BV_TYPE)
        add     a,a                     ; 4 bpp: 2, 2 bpp: 4
.np:    ld      (BV_NPK),a
.px:    ld      hl,(BV_XSQ)             ; inside: xc^2 < r^2
        ld      bc,(BV_R2)
        or      a
        sbc     hl,bc
        ld      a,0
        jp      nc,.put
        ld      a,(BV_XC)               ; the longitude step
        add     a,128
        ld      c,a
        ld      a,(BV_F)
        ld      l,a
        ld      h,high BD_BND
        inc     l
.lo:    ld      a,c
        cp      (hl)
        jr      z,.lo1
        jr      c,.lo1
        inc     l
        jr      .lo
.lo1:   dec     l
        ld      a,l
        ld      (BV_F),a
        ld      a,(BV_TYPE)
        or      a
        jr      z,.v8
        dec     a
        jr      z,.v4
        ld      a,(BV_F)                ; 2 bpp: 1 + (f / 8 + lat) mod 3
        rrca
        rrca
        rrca
        and     7
        ld      hl,BV_LAT
        add     a,(hl)
.m3:    sub     3
        jr      nc,.m3
        add     a,4
        jr      .put
.v4:    ld      a,(BV_F)                ; 4 bpp: 1 + 6 (lat & 1) + 3 (f & 15) / 8
        and     15
        ld      c,a
        add     a,a
        add     a,c
        rrca
        rrca
        rrca
        and     7
        inc     a
        ld      c,a
        ld      a,(BV_LAT)
        rrca
        ld      a,c
        jr      nc,.put
        add     a,6
        jr      .put
.v8:    ld      a,(BV_XC)               ; 8 bpp: the shade
        ld      hl,BV_H
        add     a,(hl)
        call    sq8
        ld      bc,(BV_SHY)
        add     hl,bc
        ex      de,hl
        ld      hl,BV_THR
        ld      b,3
        ld      c,128
.sh:    ld      a,e
        sub     (hl)
        inc     hl
        ld      a,d
        sbc     a,(hl)
        inc     hl
        jr      c,.sh1
        ld      a,c
        add     a,32
        ld      c,a
.sh1:   djnz    .sh
        ex      de,hl
        ld      a,(BV_F)
        and     15
        ld      b,a
        ld      a,(BV_LAT)
        rrca
        ld      a,b
        jr      nc,.l0
        add     a,16
.l0:    add     a,c
        ; ---- pack and store A
.put:   ld      c,a
        ld      a,(BV_TYPE)
        or      a
        jr      nz,.pk
        ld      a,c
        jr      .st
.pk:    dec     a                       ; 4 bpp: 4 bits, 2 bpp: 2
        ld      a,(BV_ACC)
        jr      nz,.p2
        add     a,a
        add     a,a
.p2:    add     a,a
        add     a,a
        or      c
        ld      (BV_ACC),a
        ld      hl,BV_NPK
        dec     (hl)
        jr      nz,.nx
        ld      c,a
        ld      a,(BV_TYPE)
        add     a,a
        ld      (hl),a
        xor     a
        ld      (BV_ACC),a
        ld      a,c
.st:    ld      hl,(BV_DST)
        ld      (hl),a
        inc     hl
        ld      (BV_DST),hl
.nx:    ld      a,(BV_XC)               ; xc^2 += 4 xc + 4; xc += 2
        ld      l,a
        rla
        sbc     a,a
        ld      h,a
        add     hl,hl
        add     hl,hl
        ld      bc,4
        add     hl,bc
        ld      bc,(BV_XSQ)
        add     hl,bc
        ld      (BV_XSQ),hl
        ld      hl,BV_XC
        inc     (hl)
        inc     (hl)
        ld      hl,BV_X
        dec     (hl)
        jp      nz,.px
        ld      hl,BV_Y
        inc     (hl)
        ld      a,(BV_D)
        cp      (hl)
        jp      nz,.row
        ret

; A x E -> HL, unsigned (B, D changed)
mul8:   ld      hl,0
        ld      d,h
        ld      b,8
.m:     add     hl,hl
        rla
        jr      nc,.n
        add     hl,de
.n:     djnz    .m
        ret

; A (signed) squared -> HL (B, D, E changed)
sq8:    bit     7,a
        jr      z,.p
        neg
.p:     ld      e,a
        jr      mul8

; floor(sqrt(HL)) -> A (B, DE, HL changed)
isqrt:  ld      de,1
        ld      b,0
.l:     or      a
        sbc     hl,de
        jr      c,.d
        inc     b
        inc     de
        inc     de
        jr      .l
.d:     ld      a,b
        ret

bdthk:  db      6, 15, 26
; sin(-90 + 22.5j) x 256, j = 1-7: magnitude, then 1 if negative
bdslat: db      237, 1, 181, 1, 98, 1, 0, 0, 98, 0, 181, 0, 237, 0
; cos(2.8125j) x 255, j = 1-31: the longitude boundaries' magnitudes
bdslon: db      255, 254, 252, 250, 247, 244, 240, 236, 231, 225, 219, 212, 205, 197, 189
        db      180, 171, 162, 152, 142, 131, 120, 109, 98, 86, 74, 62, 50, 37, 25, 12

; ================================================================ colours
; The 8 bpp balls' colours: for each shade, 48 entries of 8 red, 8 white
; (blue, green, red each); entries 128 + 32 s + 16 l + f take strip entry
; t + f (latitude 0) or t + 8 + f (latitude 1) at phase t
bdstrips:
        ld      de,BD_STR8
        ld      hl,bdc8
        ld      b,4
.s:     push    bc
        ld      c,6                     ; 6 runs of 8
.r:     ld      b,8
.e:     push    hl
        ldi
        ldi
        ldi
        inc     bc
        inc     bc
        inc     bc
        pop     hl
        djnz    .e
        ld      a,l                     ; the other colour
        xor     3                       ; (red at +0, white at +3: bdc8 aligned below)
        ld      l,a
        dec     c
        jr      nz,.r
        ld      bc,8
        add     hl,bc
        pop     bc
        djnz    .s
        ret

; The 4 bpp balls' strip: 3 red, 3 white, 16 entries; entries 1-6 take
; strip entries t to t + 5 at phase t (0-5), entries 7-12 t + 3 to t + 8
bdstr4: db      0x18, 0x20, 0xE0,  0x18, 0x20, 0xE0,  0x18, 0x20, 0xE0
        db      0xE8, 0xE8, 0xE8,  0xE8, 0xE8, 0xE8,  0xE8, 0xE8, 0xE8
        db      0x18, 0x20, 0xE0,  0x18, 0x20, 0xE0,  0x18, 0x20, 0xE0
        db      0xE8, 0xE8, 0xE8,  0xE8, 0xE8, 0xE8,  0xE8, 0xE8, 0xE8
        db      0x18, 0x20, 0xE0,  0x18, 0x20, 0xE0
; The 2 bpp balls' strip: red, white, pink, twice
bdstr2: db      0x18, 0x20, 0xE0,  0xE8, 0xE8, 0xE8,  0xA0, 0xA0, 0xFF
        db      0x18, 0x20, 0xE0,  0xE8, 0xE8, 0xE8,  0xA0, 0xA0, 0xFF

; The scroller's palette: PALETTE0 blocks 1-5, entries 1-3 (the F, its
; shadow, the dot): blue, green, red
bdtpal: db      0xC0, 0x40, 0x40,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 1 blue
        db      0x20, 0xA0, 0x20,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 2 green
        db      0x00, 0x90, 0xD0,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 3 orange
        db      0xC0, 0x00, 0x80,  0x00, 0x00, 0x00,  0xA0, 0xA0, 0xA0     ; 4 purple
        db      0x80, 0x60, 0x60,  0x00, 0x00, 0x00,  0x80, 0x60, 0x60     ; 5 grey dot

; L0 as a tile map over the whole picture, 2 x 2, 64 x 32 entries
bdl0:   db      L0_CTRL1, 1 << L_CTRL1_VSCALE_B
        db      L0_CTRL2, 0
        db      L0_CTRL3, 1 << L_CTRL3_MAPW_B
        db      L0_WINX0, 864 & 0xFF, L0_WINX1, 864 >> 8
        db      L0_WINX2, 144, L0_WINX3, 0
        db      L0_WINY0, 625 & 0xFF, L0_WINY1, 625 >> 8
        db      L0_WINY2, 49, L0_WINY3, 0
        db      L0_SCROLLX0, 0, L0_SCROLLX1, 0
        db      L0_SCROLLY0, 0, L0_SCROLLY1, 0
        db      L0_MAPPT0, 0x00, L0_MAPPT1, 0x80, L0_MAPPT2, 0x1F       ; 0x1F8000
        db      L0_PATPT0, 0x00, L0_PATPT1, 0x90, L0_PATPT2, 0x1F       ; 0x1F9000
        db      0xFF

; ================================================================ the scroller
; Ticket #14's tile map (once tiledemo.asm): 64 x 32 entries; the F four
; ways on even columns and rows of each 4 x 4 block (column 2 XFLIP, row 2
; YFLIP), PAL 1-4 by the block's diagonal; dots (PAL 5) on the others
bdtiles:
        ld      hl,bdtl
        ld      de,BD_PAT
        ld      bc,bdtl_end - bdtl
        ldir
        ld      hl,BD_MAP
        ld      c,0                     ; row
.row:   ld      b,0                     ; column
.col:   ld      a,b
        or      c
        rrca
        jr      c,.dot
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
        bit     1,b
        jr      z,.nx
        set     5,e                     ; XFLIP in the block's column 2
.nx:    bit     1,c
        jr      z,.ny
        set     6,e                     ; YFLIP in the block's row 2
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
        ret

; The patterns: 8 rows of 4 bytes, two pixels a byte, the left one high
bdtl:   ds      32, 0                   ; 0: blank
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
bdtl_end:

; The 8 bpp colours by shade, red then white (blue, green, red), from the
; light to the dark, 8 bytes a shade, on a multiple of 8, so bdstrips can
; go between the two by xor 3 of the low address byte
        IF      $ & 7
        ds      8 - ($ & 7), 0xFF
        ENDIF
bdc8:   db      0x60, 0x70, 0xFF,  0xFF, 0xFF, 0xFF,  0, 0
        db      0x18, 0x20, 0xE0,  0xD8, 0xD8, 0xD8,  0, 0
        db      0x10, 0x10, 0xA0,  0xA8, 0xA0, 0xA0,  0, 0
        db      0x08, 0x08, 0x60,  0x68, 0x60, 0x60,  0, 0

; The demo's IM 2 table: 24 entries, VBLANK (source 0) first
        IF      $ & 255
        ds      256 - ($ & 255), 0xFF
        ENDIF
bdivt:  dw      bdvbl
        dup     23
        dw      bdspur
        edup
