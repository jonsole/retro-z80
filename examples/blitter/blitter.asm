; The blitter on the board (ticket #39): a first look at the DMA engine.
; It turns layer L0 into a 360 x 288 8 bpp bitmap at physical 0x020000,
; then runs a chain of blitter jobs on channel 0:
;   1. clear the screen to dark blue (a fill)
;   2. a green rectangle (a 2D fill)
;   3. a diamond with a transparent colour (cookie-cut, compare mask),
;      drawn three times, once over the rectangle's edge
;   4. a band XORed with 7 (minterm 0x66, which reads the old screen),
;      across the rectangle and a diamond: every colour in it changes
; When the chain is done the border turns green (red on an error).
; The console is gone afterwards: press the reset button to get it back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PHYS    equ     0                       ; the program map: a Z80 address is its own physical address (boot ROM spec, section 5.1)
SCREEN  equ     0x020000                ; physical
W       equ     360
H       equ     288

    MACRO WREG xp, xv                   ; write xv to register port xp
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    ; A job: CTRL0, CTRL1, MINTERM, APT, BPT, DPT, WIDTH, HEIGHT, SHIFT,
    ; ABSTRIDE, CDSTRIDE, VALUE, NEXT
    MACRO JOB c0, c1, mt, apt, bpt, dpt, wid, hgt, sh, abs, cds, val, nxt
        db      c0, c1, 0, mt
        d24     apt, bpt, dpt, wid
        dw      hgt, sh, abs, cds
        dd      val
        d24     nxt
        db      0
    ENDM

B8      equ     0x03                    ; CTRL1: 8 bpp
BCONST  equ     0x10
MKEY    equ     0x40                    ; mask from comparing B with the key colour

start:  di
        ; the palette: 0 black, 1 dark blue, 2 green, 3 white, 4 yellow, 5 red,
        ; 6 cyan, 7 magenta (XOR 7 swaps 1 and 6, 2 and 5, 3 and 4)
        WREG    PALIDX0_P, 0
        WREG    PALIDX1_P, 0
        ld      hl,colours
        ld      bc,PALDAT_P
        ld      d,8 * 3
.pal:   ld      a,(hl)
        out     (c),a
        inc     hl
        dec     d
        jr      nz,.pal

        ; L0: an 8 bpp bitmap, 2x across and down, the whole picture
        ld      hl,l0regs
.l0:    ld      a,(hl)                  ; register port low byte (high byte), then the value
        or      a
        jr      z,.l0done
        ld      b,a
        inc     hl
        ld      c,(hl)
        inc     hl
        ld      a,(hl)
        inc     hl
        out     (c),a
        jr      .l0
.l0done:
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BPLEN_M | DMACON_BLTEN_M

        ; the chain, on channel 0
        WREG    DMX0_CHDESC0_P, low (job1 + PHYS)
        WREG    DMX0_CHDESC1_P, high (job1 + PHYS)
        WREG    DMX0_CHDESC2_P, (job1 + PHYS) >> 16
        WREG    DMX0_CHCTRL_P, DMX_CHCTRL_START_M
        ld      bc,DMX0_CHSTAT_P
.wait:  in      a,(c)
        rra
        jr      c,.wait
        ld      e,0x00                  ; border: green, or red on an error
        ld      d,0xC0
        and     DMX_CHSTAT_ERR_M >> 1
        jr      z,.ok
        ld      e,0xC0
        ld      d,0x00
.ok:    ld      bc,BGCOLOR0_P           ; blue, green, red
        xor     a
        out     (c),a
        ld      bc,BGCOLOR1_P
        out     (c),d
        ld      bc,BGCOLOR2_P
        out     (c),e
        ; Each frame, in the vertical blank, point L0 at the screen again:
        ; nothing resets BPL0PT at the frame start (spec 4, section 4.4)
done:   ld      bc,VIDSTAT_P
.vb:    in      a,(c)
        and     VIDSTAT_VBLANK_M
        jr      z,.vb
        out     (c),a                   ; W1C
        WREG    L0_BPL0PT0_P, SCREEN & 0xFF
        WREG    L0_BPL0PT1_P, (SCREEN >> 8) & 0xFF
        WREG    L0_BPL0PT2_P, SCREEN >> 16
        jr      done

colours:
        db      0x00, 0x00, 0x00        ; blue, green, red
        db      0x60, 0x10, 0x00
        db      0x20, 0xA0, 0x20
        db      0xFF, 0xFF, 0xFF
        db      0x00, 0xE0, 0xFF
        db      0x00, 0x00, 0xE0
        db      0xE0, 0xE0, 0x00
        db      0xE0, 0x00, 0xE0

l0regs: db      high L0_CTRL0_P, low L0_CTRL0_P, L_CTRL0_EN_M | (3 << L_CTRL0_BPP_B) | (1 << L_CTRL0_HSCALE_B)
        db      high L0_CTRL1_P, low L0_CTRL1_P, 1 << L_CTRL1_VSCALE_B
        db      high L0_CTRL2_P, low L0_CTRL2_P, 0
        db      high L0_CTRL3_P, low L0_CTRL3_P, 0
        db      high L0_WINX0_P, low L0_WINX0_P, 864 & 0xFF
        db      high L0_WINX1_P, low L0_WINX1_P, 864 >> 8
        db      high L0_WINX2_P, low L0_WINX2_P, 144
        db      high L0_WINX3_P, low L0_WINX3_P, 0
        db      high L0_WINY0_P, low L0_WINY0_P, 625 & 0xFF
        db      high L0_WINY1_P, low L0_WINY1_P, 625 >> 8
        db      high L0_WINY2_P, low L0_WINY2_P, 49
        db      high L0_WINY3_P, low L0_WINY3_P, 0
        db      high L0_SCROLLX0_P, low L0_SCROLLX0_P, 0
        db      high L0_SCROLLX1_P, low L0_SCROLLX1_P, 0
        db      high L0_SCROLLY0_P, low L0_SCROLLY0_P, 0
        db      high L0_SCROLLY1_P, low L0_SCROLLY1_P, 0
        db      high L0_BPLSTRIDE0_P, low L0_BPLSTRIDE0_P, W & 0xFF
        db      high L0_BPLSTRIDE1_P, low L0_BPLSTRIDE1_P, W >> 8
        db      high L0_BPL0PT0_P, low L0_BPL0PT0_P, SCREEN & 0xFF
        db      high L0_BPL0PT1_P, low L0_BPL0PT1_P, (SCREEN >> 8) & 0xFF
        db      high L0_BPL0PT2_P, low L0_BPL0PT2_P, SCREEN >> 16
        db      0

        align   4
job1:   JOB     0, B8|BCONST, 0xCC, 0, 0, SCREEN, W*H, 1, 0, 0, 0, 0x01010101, job2+PHYS
job2:   JOB     0, B8|BCONST, 0xCC, 0, 0, SCREEN+60*W+40, 120, 80, 0, 0, W, 0x02020202, job3+PHYS
job3:   JOB     0, B8|MKEY, 0xCA, 0, diamond+PHYS, SCREEN+130*W+150, 16, 16, 0, 16, W, 0, job4+PHYS
job4:   JOB     0, B8|MKEY, 0xCA, 0, diamond+PHYS, SCREEN+52*W+152, 16, 16, 0, 16, W, 0, job5+PHYS
job5:   JOB     0, B8|MKEY, 0xCA, 0, diamond+PHYS, SCREEN+200*W+250, 16, 16, 0, 16, W, 0, job6+PHYS
job6:   JOB     0, B8|BCONST, 0x66, 0, 0, SCREEN+120*W+20, 200, 30, 0, 0, W, 0x07070707, 0

; A 16 x 16 diamond, 8 bpp: white inside, yellow edge, 0 (transparent) outside
diamond:
r = 0
        DUP     16
c = 0
        DUP     16
        IF r < 8
dr = 7 - r
        ELSE
dr = r - 8
        ENDIF
        IF c < 8
dc = 7 - c
        ELSE
dc = c - 8
        ENDIF
        IF dr + dc <= 5
        db      3
        ELSE
        IF dr + dc <= 7
        db      4
        ELSE
        db      0
        ENDIF
        ENDIF
c = c + 1
        EDUP
r = r + 1
        EDUP
