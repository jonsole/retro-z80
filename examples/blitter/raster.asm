; The rasteriser on the board (ticket #110): a first look. It turns layer
; L0 into a 360 x 288 8 bpp bitmap at physical 0x020000, clears it with one
; blitter job, sets the clip window to the bitmap, then runs a chain of
; rasteriser jobs from descriptors in memory:
;   1. a red and a green triangle sharing an edge (each pixel on it drawn once)
;   2. a fan of eight white lines
;   3. a dashed yellow line (PATTERN 0xF0F0, minterm 0xCA: the pattern's 0
;      bits leave the screen alone)
;   4. a cyan line from far outside the window on both sides (clipped)
;   5. a triangle XORed with 7 over the others
; When both are done the border turns green (red on an error).
; The console is gone afterwards: press the reset button to get it back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PHYS    equ     0                       ; the program map: a Z80 address is its own physical address
SCREEN  equ     0x020000                ; physical
W       equ     360
H       equ     288

    MACRO WREG xp, xv                   ; write xv to register port xp
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    ; A rasteriser job, as its registers and a descriptor (spec 19, section 3):
    ; RASCTRL, RASP0, RASP1, RASP2 (each Y then X), RASDPT, RASSTRIDE,
    ; RASPAT, RASNEXT, each low byte first
    MACRO RJOB ctl, x0, y0, x1, y1, x2, y2, pat, nxt
        dd      ctl
        dw      y0, x0, y1, x1, y2, x2
        dd      SCREEN, W, pat
        dd      nxt
    ENDM

B8      equ     3 << RASCTRL_BPP_B      ; 8 bpp
TRI     equ     RASCTRL_TRI_M
MT      equ     1 << RASCTRL_MINTERM_B  ; MINTERM x: x * MT; VALUE (the colour) in bits 7-0

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

        ; L0: an 8 bpp bitmap, 2x across and down, in a window 32 pixels in
        ; from each edge, so the background colour shows round it
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

        ; clear the screen: one blitter job, run from its registers
        ld      hl,clear
        ld      bc,BLTCTRL0_P
.ld:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high BLTCTRL0_P + 32
        jr      nz,.ld
        WREG    BLTCMD_P, BLTCMD_RUN_M
        ld      bc,BLTSTAT_P
.bw:    in      a,(c)
        rra
        jr      c,.bw

        ; the clip window: the whole bitmap, (0, 0) to (W - 1, H - 1)
        ld      hl,clipw
        ld      bc,RASCLIPMIN0_P
.cl:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high RASCLIPMIN0_P + 8
        jr      nz,.cl

        ; the rasteriser's chain
        WREG    RASDESC0_P, low (job1 + PHYS)
        WREG    RASDESC1_P, high (job1 + PHYS)
        WREG    RASDESC2_P, (job1 + PHYS) >> 16
        WREG    RASCMD_P, RASCMD_START_M
        ld      bc,RASSTAT_P
.wait:  in      a,(c)
        rra
        jr      c,.wait
        ld      d,a                     ; RASSTAT >> 1
        ld      bc,BLTSTAT_P
        in      a,(c)
        rra
        or      d
        ld      e,0x00                  ; border: green, or red on an error
        ld      d,0xC0
        and     RASSTAT_ERR_M >> 1
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
        db      high L0_WINX0_P, low L0_WINX0_P, (864 - 32) & 0xFF
        db      high L0_WINX1_P, low L0_WINX1_P, (864 - 32) >> 8
        db      high L0_WINX2_P, low L0_WINX2_P, 144 + 32
        db      high L0_WINX3_P, low L0_WINX3_P, 0
        db      high L0_WINY0_P, low L0_WINY0_P, (625 - 32) & 0xFF
        db      high L0_WINY1_P, low L0_WINY1_P, (625 - 32) >> 8
        db      high L0_WINY2_P, low L0_WINY2_P, 49 + 32
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
; the blitter's clear: 8 bpp, B = VALUE, D = B; colour 1 in both bytes
clear:  dd      (3 << BLTCTRL_BPP_B) | BLTCTRL_BCONST_M | (0xCC << BLTCTRL_MINTERM_B)
        dd      0, SCREEN
        dw      W, H
        dd      0
        dw      W, 0, 0x0101, 0
        dd      0

clipw:  dw      0, 0, H - 1, W - 1      ; YMIN, XMIN, YMAX, XMAX

CX      equ     280                     ; the fan's centre
CY      equ     140
job1:   RJOB    B8|TRI|0xCC*MT|5, 40, 40, 160, 60, 80, 200, 0xFFFF, job2+PHYS
job2:   RJOB    B8|TRI|0xCC*MT|2, 160, 60, 80, 200, 220, 180, 0xFFFF, job3+PHYS
job3:   RJOB    B8|0xCC*MT|3, CX, CY, CX+70, CY, 0, 0, 0xFFFF, job4+PHYS
job4:   RJOB    B8|0xCC*MT|3, CX, CY, CX+49, CY+49, 0, 0, 0xFFFF, job5+PHYS
job5:   RJOB    B8|0xCC*MT|3, CX, CY, CX, CY+70, 0, 0, 0xFFFF, job6+PHYS
job6:   RJOB    B8|0xCC*MT|3, CX, CY, CX-49, CY+49, 0, 0, 0xFFFF, job7+PHYS
job7:   RJOB    B8|0xCC*MT|3, CX, CY, CX-70, CY, 0, 0, 0xFFFF, job8+PHYS
job8:   RJOB    B8|0xCC*MT|3, CX, CY, CX-49, CY-49, 0, 0, 0xFFFF, job9+PHYS
job9:   RJOB    B8|0xCC*MT|3, CX, CY, CX, CY-70, 0, 0, 0xFFFF, job10+PHYS
job10:  RJOB    B8|0xCC*MT|3, CX, CY, CX+49, CY-49, 0, 0, 0xFFFF, job11+PHYS
job11:  RJOB    B8|0xCA*MT|4, 20, 262, 340, 248, 0, 0, 0xF0F0, job12+PHYS
job12:  RJOB    B8|0xCC*MT|6, -2000, 20, 2400, 34, 0, 0, 0xFFFF, job13+PHYS
job13:  RJOB    B8|TRI|0x66*MT|7, 100, 120, 320, 100, 200, 275, 0xFFFF, 0
