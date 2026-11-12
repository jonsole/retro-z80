; Example 6-7 (docs/guide/blitter.md): objects on a screen split between 8 bpp and 4 bpp.
; One layer, L0, shows a 360 x 288 picture. The top half (source lines 0-143)
; is 8 bpp, 360 bytes a row: a sunset of 48 shades and two lit spheres of 24
; shades each, in palette entries the program loads. The bottom half (lines
; 144-287) is 4 bpp, 180 bytes a row, straight after the top half in memory:
; a sea of 6 shades and balls of 4 shades, from one block of 16 palette
; entries. A copper list changes L0's depth, palette block and stride where
; the bottom half starts. Four 32 x 32 balls bounce in each half. Each frame
; one chain of
; blitter jobs restores the background under every ball, then saves the
; background and draws the ball, for each ball in turn. A key ends it, puts the
; palette back and prints how long the chain and the Z80's preparation took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

SAVE    equ     0x060000                ; physical: 1,024 bytes a ball for the saved background
BOT     equ     SCREEN + 144 * 360      ; the bottom half starts after the top half's 144 rows
SPLIT   equ     VID_Y0 + 2 * 144 - 1    ; beam line 336: the last line of the top half
NOBJ    equ     8                       ; four balls in each half
JOBSZ   equ     96                      ; a ball's three jobs
CTRL0_8 equ     L_CTRL0_EN_M | (3 << L_CTRL0_BPP_B) | (1 << L_CTRL0_HSCALE_B)
CTRL0_4 equ     L_CTRL0_EN_M | (2 << L_CTRL0_BPP_B) | (1 << L_CTRL0_HSCALE_B)
PALBLK  equ     9                       ; the 4 bpp half's palette block: entries 144-159
CTRL1_8 equ     1 << L_CTRL1_VSCALE_B   ; 2x down, PALOFS 0
CTRL1_4 equ     (1 << L_CTRL1_VSCALE_B) | (PALBLK << L_CTRL1_PALOFS_B)

start:  ld      a,3                     ; L0 starts as the top half: 8 bpp,
        ld      hl,360                  ; 360 bytes a row
        call    scr_on
        call    setpal                  ; the 8 bpp half's colours
        ld      hl,bands                ; the two backgrounds: a chain of fills
        call    bltstart
        call    bltwait

        ld      bc,COPCON_P             ; the copper: off while it is set up
        xor     a
        out     (c),a
        ld      hl,copl                 ; its list, run from the top of every frame
        ld      bc,COP1LC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        out     (c),a
        ld      b,low COPCON
        ld      a,COPCON_EN_M
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M | DMACON_COPEN_M
        out     (c),a

        call    prepare                 ; the balls' first places into the jobs

loop:   call    frame                   ; the vertical blank has begun

        call    t0
        ld      hl,(first)              ; frame 1 has nothing to restore
        call    bltstart
        ld      hl,restores
        ld      (first),hl
        call    bltwait
        call    t1
        ld      de,listmax
        call    maxw

        call    t0
        call    prepare                 ; next frame's places into the jobs
        call    t1
        ld      de,prepmax
        call    maxw

        rst     20h                     ; POLLC: a key ends it
        jr      z,loop

        ld      bc,DMACON_P             ; put everything back: the copper off
        ld      a,DMACON_COPEN_M        ; (SETCLR 0: clear)
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        call    bltwait
        call    clrpal
        call    scr_off
        ld      hl,msg1
        rst     18h                     ; PUTS
        ld      hl,(listmax)
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,msg2
        rst     18h
        ld      hl,(prepmax)
        rst     28h
        db      0x08
        ld      hl,msg3
        rst     18h
        ret                             ; back to the monitor

msg1:   db      "The longest chain took ", 0
msg2:   db      " us; preparing the next frame took ", 0
msg3:   db      " us", 13, 10, 0
first:  dw      objs + 32               ; the first ball's save job
cnt:    db      0
listmax: dw     0
prepmax: dw     0

; The copper list. At the top of each frame (in the vertical blank) L0 is the
; top half: 8 bpp, PALOFS 0, 360 bytes a row. The depth is taken as each
; group of 16 source pixels starts, so it changes after line 336's last group
; has begun showing (beam pixel 848) and before line 337 starts. PALOFS acts
; at once, so it changes in line 337's horizontal blank. The stride is read
; at the end of each line (beam pixel 0), so line 336 still steps 360 bytes
; on, to the start of the bottom half; 180 is written in the middle of line
; 337, well clear of that moment (a write in the same few clocks may be
; read a line early), in time for the end of line 338, the last copy of
; source line 144.
        align   2
copl:   CMOVE   L0_CTRL0,CTRL0_8
        CMOVE   L0_CTRL1,CTRL1_8
        CMOVE   L0_BPLSTRIDE0,low 360
        CMOVE   L0_BPLSTRIDE1,high 360
        CWAIT   SPLIT,852               ; line 336's last group is showing
        CMOVE   L0_CTRL0,CTRL0_4        ; 4 bpp from line 337's first group
        CWAIT   SPLIT+1,0               ; line 337's horizontal blank
        CMOVE   L0_CTRL1,CTRL1_4        ; the bottom half's palette block
        CWAIT   SPLIT+1,400             ; well clear of the end of line 336
        CMOVE   L0_BPLSTRIDE0,low 180
        CMOVE   L0_BPLSTRIDE1,high 180  ; 180 bytes a row for the rest of the frame
        CSTOP

; setpal: load the entries of paltab (index, blue, green, red) into palette 0.
; The console uses entries 16 and 17 of every block of 16, so paltab keeps off them.
setpal: ld      bc,PALIDX1_P
        xor     a
        out     (c),a                   ; palette 0
        ld      hl,paltab
        ld      e,PALN
.entry: ld      bc,PALIDX_P
        ld      a,(hl)
        inc     hl
        out     (c),a                   ; the entry (this also starts PALDAT at blue)
        ld      bc,PALDAT_P
        ld      a,(hl)
        inc     hl
        out     (c),a                   ; blue
        ld      a,(hl)
        inc     hl
        out     (c),a                   ; green
        ld      a,(hl)
        inc     hl
        out     (c),a                   ; red: the entry changes
        dec     e
        jr      nz,.entry
        ret

; clrpal: the same entries back to black, as they were at power-on
clrpal: ld      hl,paltab
        ld      e,PALN
.entry: ld      bc,PALIDX_P
        ld      a,(hl)
        inc     hl
        out     (c),a
        inc     hl
        inc     hl
        inc     hl
        ld      bc,PALDAT_P
        xor     a
        out     (c),a
        out     (c),a
        out     (c),a
        dec     e
        jr      nz,.entry
        ret

; prepare: for each ball, put it where it goes next. The blitter is idle, so
; the jobs can be written. IX is the ball's record, IY its three jobs.
prepare:
        ld      ix,objtab
        ld      a,NOBJ
        ld      (cnt),a
.obj:   ld      l,(ix+8)
        ld      h,(ix+9)
        push    hl
        pop     iy
        ; 1. restore puts the saved background where the ball was drawn
        ld      a,(iy+64+8)
        ld      (iy+8),a                ; BLTDPT
        ld      a,(iy+64+9)
        ld      (iy+9),a
        ld      a,(iy+64+10)
        ld      (iy+10),a
        ld      a,(iy+64+11)
        ld      (iy+11),a               ; and its DBIT
        ; 2. move the ball, bouncing at the edges of its half
        ld      l,(ix+0)
        ld      h,(ix+1)
        ld      e,(ix+4)
        ld      d,(ix+5)
        ld      bc,328                  ; x runs 0-328 (360 - 32)
        call    bounce
        ld      (ix+0),l
        ld      (ix+1),h
        ld      (ix+4),e
        ld      (ix+5),d
        ld      l,(ix+2)
        ld      h,(ix+3)
        ld      e,(ix+6)
        ld      d,(ix+7)
        ld      bc,112                  ; y runs 0-112 (144 - 32), from the half's top
        call    bounce
        ld      (ix+2),l
        ld      (ix+3),h
        ld      (ix+6),e
        ld      (ix+7),d
        ; 3. the address: base + y * row + the byte holding pixel x
        ld      l,(ix+2)
        ld      h,(ix+3)
        ld      e,(ix+10)
        ld      d,(ix+11)
        call    mul                     ; HL = y * row
        ld      e,(ix+0)
        ld      d,(ix+1)
        ld      c,0                     ; C = the pixel's place in its byte
        ld      a,(ix+15)
        or      a
        jr      z,.byte                 ; 8 bpp: a pixel is a byte
        srl     d
        rr      e                       ; 4 bpp: x / 2 ...
        ld      a,0
        rla                             ; ... and x mod 2, from the carry
        ld      c,a
.byte:  add     hl,de
        ld      e,(ix+12)
        ld      d,(ix+13)
        add     hl,de
        ld      a,(ix+14)
        adc     a,0                     ; A:HL = the 24-bit address
        ; 4. into the save and draw jobs
        ld      (iy+32+4),l             ; save: BLTBPT
        ld      (iy+32+5),h
        ld      (iy+32+6),a
        ld      (iy+64+8),l             ; draw: BLTDPT
        ld      (iy+64+9),h
        ld      (iy+64+10),a
        ld      a,c
        ld      (iy+32+7),a             ; save: BBIT = x mod 2, BLTBPT bits 26-24
        ld      (iy+64+11),a            ; draw: DBIT = x mod 2, BLTDPT bits 26-24
        ld      de,16
        add     ix,de
        ld      a,(cnt)
        dec     a
        ld      (cnt),a
        jp      nz,.obj
        ret

; bounce: HL = position, DE = step, BC = the highest position. Steps the
; position; past either end it stops at the end and the step turns round.
bounce: add     hl,de
        bit     7,h
        jr      nz,.low                 ; below 0
        push    hl
        or      a
        sbc     hl,bc
        pop     hl
        ret     c                       ; below the highest
        ret     z                       ; at the highest
        ld      h,b                     ; past it: stop at it
        ld      l,c
        jr      .turn
.low:   ld      hl,0
.turn:  push    hl
        ld      hl,0
        or      a
        sbc     hl,de
        ex      de,hl                   ; step = -step
        pop     hl
        ret

; mul: HL = HL * DE (16 bits)
mul:    ld      b,h
        ld      c,l
        ld      hl,0
        ld      a,16
.bit:   add     hl,hl
        sla     c
        rl      b
        jr      nc,.next
        add     hl,de
.next:  dec     a
        jr      nz,.bit
        ret

; maxw: HL = a time, DE -> the word that holds the largest so far
maxw:   ld      a,(de)
        sub     l
        inc     de
        ld      a,(de)
        sbc     a,h
        dec     de
        ret     nc
        ld      a,l
        ld      (de),a
        inc     de
        ld      a,h
        ld      (de),a
        ret

; The balls: x, y, dx, dy, their jobs, the row length, the half's address
; (3 bytes) and the shift: 0 for 8 bpp, 1 for 4 bpp (a pixel is half a byte).
    MACRO BALL k, x, y, dx, dy, row, base, shift
        dw      x, y, dx, dy
        dw      objs + JOBSZ * k
        dw      row
        dw      base & 0xFFFF
        db      base >> 16, shift
    ENDM
objtab: BALL    0, 20,  10,  2,  1, 360, SCREEN, 0
        BALL    1, 120, 60, -3,  2, 360, SCREEN, 0
        BALL    2, 220, 30,  1, -2, 360, SCREEN, 0
        BALL    3, 300, 90, -2, -1, 360, SCREEN, 0
        BALL    4, 50,  80,  2, -2, 180, BOT,    1
        BALL    5, 150, 20, -1,  3, 180, BOT,    1
        BALL    6, 250, 50,  3,  1, 180, BOT,    1
        BALL    7, 320, 100,-2,  2, 180, BOT,    1

; The jobs. A ball has three: restore, save and draw (Figure 6-11). The chain
; runs every ball's restore, last ball first, then each ball's save and draw
; in turn, so balls that overlap are put back in the opposite order to the one
; they were drawn in. BLTDPT and BLTBPT are set each frame; BLTNEXT and
; BLTDESC take a job's own Z80 address, which in the program map is its
; physical address.
        align   2
    MACRO OBJ k, bpp, row, brow, img, sv
        dd      0xCC*MT | bpp           ; restore: copy the saved background back
        dd      sv, 0                   ; BLTBPT: the saved background; BLTDPT (and DBIT): set each frame
        dw      32, 32                  ; WIDTH, HEIGHT: 32 pixels
        dd      0
        dw      row, brow               ; DSTRIDE: the screen's rows; BSTRIDE: SAVE's
        dw      0, 0
        IF k > 0
        dd      objs + JOBSZ * (k - 1)  ; BLTNEXT: the restore of the ball before
        ELSE
        dd      objs + 32               ; BLTNEXT: the first ball's save
        ENDIF

        dd      0xCC*MT | bpp           ; save: copy the background under the ball
        dd      0, sv                   ; BLTBPT (and BBIT): set each frame; BLTDPT: SAVE
        dw      32, 32
        dd      0
        dw      brow, row               ; DSTRIDE: SAVE's rows; BSTRIDE: the screen's
        dw      0, 0
        dd      objs + JOBSZ * k + 64   ; BLTNEXT: this ball's draw

        dd      0xCA*MT | MASKKEY | bpp ; draw: A ? B : C, KEY 0
        dd      img, 0                  ; BLTBPT: the ball; BLTDPT (and DBIT): set each frame
        dw      32, 32
        dd      0
        dw      row, brow               ; DSTRIDE: the screen's rows; BSTRIDE: the ball's
        dw      0, 0
        IF k < NOBJ - 1
        dd      objs + JOBSZ * (k + 1) + 32     ; BLTNEXT: the next ball's save
        ELSE
        dd      0                       ; BLTNEXT: the end of the chain
        ENDIF
    ENDM
objs:   OBJ     0, BPP8, 360, 32, ball8a, SAVE
        OBJ     1, BPP8, 360, 32, ball8b, SAVE + 1 * 1024
        OBJ     2, BPP8, 360, 32, ball8a, SAVE + 2 * 1024
        OBJ     3, BPP8, 360, 32, ball8b, SAVE + 3 * 1024
        OBJ     4, BPP4, 180, 16, ball4a, SAVE + 4 * 1024
        OBJ     5, BPP4, 180, 16, ball4b, SAVE + 5 * 1024
        OBJ     6, BPP4, 180, 16, ball4a, SAVE + 6 * 1024
        OBJ     7, BPP4, 180, 16, ball4b, SAVE + 7 * 1024
restores equ    objs + JOBSZ * (NOBJ - 1)       ; the list starts with the last ball's restore

; Palette entry for colour number n: skip the console's entries (16 and 17 of
; each block of 16): 14 colours a block, from entry 18
    MACRO ENTRY n
en = 16 * ((n) / 14 + 1) + 2 + (n) % 14
    ENDM

PALN    equ     48 + 24 + 24 + 6 + 4 + 4       ; 8 bpp: 0-47 the sunset, 48-71 ball A, 72-95 ball B; then the 4 bpp block's

; The 8 bpp half's background: 48 bands of 3 rows, each a fill in the next shade
; of the sunset, then the 4 bpp half's four flat bands of 36 rows
bands:
i = 0
        DUP     48
        ENTRY   i
        dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + i * 3 * 360
        dw      360, 3
        dd      0
        dw      360, 0
        dw      en * 0x0101, 0
        dd      $ + 4                   ; BLTNEXT: the band after this one
i = i + 1
        EDUP
    MACRO BAND4 n, last
        dd      0xCC*MT | BLTCTRL_BCONST_M | BPP4
        dd      0, BOT + n * 24 * 180
        dw      360, 24                 ; 360 pixels = 180 bytes
        dd      0
        dw      180, 0
        dw      (2 + n) * 0x1111, 0     ; colours 2-7 of the block
        IF last
        dd      0
        ELSE
        dd      $ + 4
        ENDIF
    ENDM
        BAND4   0, 0
        BAND4   1, 0
        BAND4   2, 0
        BAND4   3, 0
        BAND4   4, 0
        BAND4   5, 1

; The colours: index, blue, green, red
paltab:
i = 0
        DUP     48                      ; the sunset: indigo at the top to orange at the horizon
        ENTRY   i
        db      en, 50 + 100 * i * (47 - i) / 552 + 20 * i / 47, 150 * i / 47, 10 + 245 * i / 47
i = i + 1
        EDUP
    MACRO RAMP n0, r0, g0, b0, r1, g1, b1
s = 0
        DUP     24
t = (s * s * 100 / 529 + s * 100 / 23) / 2   ; between linear and slow at the dark end
        ENTRY   n0 + s
        db      en, b0 + (b1 - b0) * t / 100, g0 + (g1 - g0) * t / 100, r0 + (r1 - r0) * t / 100
s = s + 1
        EDUP
    ENDM
        RAMP    48, 20, 50, 0, 230, 255, 190    ; ball A: green to pale lime
        RAMP    72, 0, 30, 60, 210, 255, 255    ; ball B: deep blue to pale cyan
    MACRO RAMP4 k0, n, r0, g0, b0, r1, g1, b1
s = 0
        DUP     n
t = s * 100 / (n - 1)
        db      16 * PALBLK + k0 + s, b0 + (b1 - b0) * t / 100, g0 + (g1 - g0) * t / 100, r0 + (r1 - r0) * t / 100
s = s + 1
        EDUP
    ENDM
        RAMP4   2, 6, 70, 150, 170, 0, 20, 60   ; the sea: pale at the horizon to deep blue
        RAMP4   8, 4, 120, 40, 0, 255, 230, 120 ; ball A: orange, 4 shades
        RAMP4   12, 4, 110, 10, 70, 255, 170, 220 ; ball B: pink, 4 shades

; An 8 bpp ball: a sphere lit from the upper left, 24 shades from entry n0
    MACRO BALL8 n0
r = 0
        DUP     32
c = 0
        DUP     32
cx = 2 * c - 31
cy = 2 * r - 31
        IF cx * cx + cy * cy <= 31 * 31
sh = 23 - ((cx + 9) * (cx + 9) + (cy + 9) * (cy + 9)) * 23 / 1900
        IF sh < 0
sh = 0
        ENDIF
        ENTRY   n0 + sh
        db      en
        ELSE
        db      0                       ; outside the ball: the key colour
        ENDIF
c = c + 1
        EDUP
r = r + 1
        EDUP
    ENDM
; A 4 bpp ball: the same sphere in 4 shades, from colour k0 of the block
    MACRO PIXEL cc, rr, k0
cx = 2 * cc - 31
cy = 2 * rr - 31
pv = 0
        IF cx * cx + cy * cy <= 31 * 31
sh = 3 - ((cx + 9) * (cx + 9) + (cy + 9) * (cy + 9)) * 3 / 1900
        IF sh < 0
sh = 0
        ENDIF
pv = k0 + sh
        ENDIF
    ENDM
    MACRO BALL4 k0
r = 0
        DUP     32
c = 0
        DUP     16
        PIXEL   c, r, k0
p0 = pv
        PIXEL   c + 1, r, k0
        db      (p0 << 4) | pv          ; two pixels a byte, the left one in the high bits
c = c + 2
        EDUP
r = r + 1
        EDUP
    ENDM
ball8a: BALL8   48
ball8b: BALL8   72
ball4a: BALL4   8
ball4b: BALL4   12

        include "screen.inc"

