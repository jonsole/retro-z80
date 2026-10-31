; Example 6-5 (docs/guide/blitter.md): drawing lines with LINE jobs.
; A starburst of 48 lines from the centre of a 360 x 288 8 bpp screen to
; points beyond a clip rectangle, which cuts them; a frame shows the
; rectangle. Below it, four lines with patterns. The routine `line` works
; out each line's octant, lengths and first pixel, and starts it on
; channel 2. A key ends it, and the console shows how long the lines took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     360                     ; bytes a row at 8 bpp
CX      equ     180                     ; the starburst's centre
CY      equ     128

start:  ld      a,BPP8
        ld      hl,ROW
        call    scr_on
        ld      hl,clsjob               ; black, and the frame round the rectangle
        call    start2
        call    wait2
        ld      hl,linejob              ; the fields every line shares
        call    load2
        ld      hl,box
        call    setclip                 ; the clip rectangle

        ld      hl,CX                   ; every ray starts at the centre
        ld      (x0),hl
        ld      hl,CY
        ld      (y0),hl
        ld      hl,ends
        ld      (ptr),hl
        ld      a,9
        ld      (col),a
        call    t0
.ray:   ld      hl,(ptr)                ; the ray's far end
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (x1),de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (y1),de
        ld      (ptr),hl
        call    wait2                   ; the last line is drawn: VALUE can change
        ld      bc,DMX2_VALUE0_P
        ld      a,(col)
        out     (c),a                   ; the colour, VALUE bits 7-0
        inc     a
        cp      16
        jr      c,.col
        ld      a,9                     ; bright blue to bright white, round again
.col:   ld      (col),a
        call    line
        ld      hl,(ptr)
        ld      de,ends_end
        or      a
        sbc     hl,de
        jr      nz,.ray
        call    wait2
        call    t1
        ld      (tray),hl

        ld      hl,whole                ; nothing clipped for the patterned lines
        call    setclip
        ld      hl,dashes
        ld      (ptr),hl
.dash:  ld      hl,(ptr)
        ld      e,(hl)                  ; the pattern
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      c,(hl)                  ; y0
        inc     hl
        ld      b,(hl)
        inc     hl
        ld      (ptr),hl
        ld      (y0),bc
        ld      hl,4
        add     hl,bc
        ld      (y1),hl                 ; y1 = y0 + 4: a gentle slope
        ld      hl,30
        ld      (x0),hl
        ld      hl,329
        ld      (x1),hl
        call    wait2
        ld      bc,DMX2_VALUE0_P
        ld      a,14                    ; bright yellow
        out     (c),a
        ld      bc,DMX2_VALUE2_P
        out     (c),e                   ; the pattern, VALUE bits 31-16
        inc     b
        out     (c),d
        call    t0
        call    lineset                 ; the Z80's part ...
        call    t1
        ld      (tset),hl
        call    t0
        call    linego                  ; ... and the engine's
        call    wait2
        call    t1
        ld      (tline),hl              ; the last line's times are kept
        ld      hl,(ptr)
        ld      de,dashes_end
        or      a
        sbc     hl,de
        jr      nz,.dash

        call    waitkey
        ld      hl,whole                ; the clip rectangle as after reset
        call    setclip
        call    scr_off
        ld      hl,msg1
        rst     18h                     ; PUTS
        ld      hl,(tray)
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,msg2
        rst     18h
        ld      hl,(tline)
        rst     28h
        db      0x08
        ld      hl,msg3
        rst     18h
        ld      hl,(tset)
        rst     28h
        db      0x08
        ld      hl,us
        rst     18h
        ret                             ; back to the monitor

msg1:   db      "48 rays took ", 0
msg2:   db      " us; a 300-pixel line ", 0
msg3:   db      " us to draw, ", 0
us:     db      " us to set up", 13, 10, 0

; line: draw the line from (x0, y0) to (x1, y1) on channel 2. x0 and y0 are
; on the screen, since the first pixel's address is worked out from them;
; x1 and y1 can be anywhere from -16,384 to 16,383, and the clip rectangle
; cuts the line. CTRL1, MINTERM, CDSTRIDE and VALUE are already in channel
; 2's registers. lineset writes the job, linego starts it. Uses AF, BC, DE, HL.
line:   call    lineset
linego: ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a                   ; draw
        ret

lineset:
        ld      c,OP_LINE               ; C = CTRL0: the operation and the octant
        ld      hl,(x1)
        ld      de,(x0)
        or      a
        sbc     hl,de                   ; dx
        jp      p,.right
        call    neghl
        set     DMX_CTRL_XNEG_B,c       ; the line goes left
.right: ld      (adx),hl
        ld      hl,(y1)
        ld      de,(y0)
        or      a
        sbc     hl,de                   ; dy
        jp      p,.down
        call    neghl
        set     DMX_CTRL_YNEG_B,c       ; the line goes up the screen
.down:  ld      de,(adx)                ; HL = |dy|, DE = |dx|
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      c,.lens                 ; |dy| < |dx|: along x
        jr      z,.lens                 ; a tie goes along x too
        set     DMX_CTRL_YMAJOR_B,c     ; |dy| > |dx|: along y
        ex      de,hl
.lens:  inc     de                      ; DE = WIDTH: the longer length + 1
        ld      (lw),de
        ld      (lh),hl                 ; HL = HEIGHT: the shorter length
        ld      a,c
        ld      (lctrl),a

        ld      hl,(y0)                 ; DPT = SCREEN + y0 * 360 + x0
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl                   ; 4 y
        push    hl
        add     hl,hl                   ; 8 y
        push    hl
        add     hl,hl
        add     hl,hl                   ; 32 y
        pop     bc
        add     hl,bc                   ; 40 y
        pop     bc
        add     hl,bc                   ; 44 y
        add     hl,de                   ; 45 y: at most 12,915
        xor     a
        add     hl,hl
        adc     a,a
        add     hl,hl
        adc     a,a
        add     hl,hl
        adc     a,a                     ; A:HL = 360 y
        ld      de,(x0)
        add     hl,de
        adc     a,SCREEN >> 16          ; SCREEN's low 16 bits are 0
        ld      e,a

        push    de
        push    hl
        call    wait2                   ; the registers can be written only while idle
        pop     hl
        pop     de
        ld      bc,DMX2_CTRL0_P
        ld      a,(lctrl)
        out     (c),a                   ; CTRL0: LINE and the octant
        ld      bc,DMX2_DPT0_P
        out     (c),l                   ; DPT: the first pixel
        inc     b
        out     (c),h
        inc     b
        out     (c),e
        ld      hl,(lw)
        inc     b
        out     (c),l                   ; WIDTH
        inc     b
        out     (c),h
        xor     a
        inc     b
        out     (c),a
        ld      hl,(lh)
        inc     b
        out     (c),l                   ; HEIGHT
        inc     b
        out     (c),h
        ld      bc,DMX2_APT0_P
        ld      hl,(x0)
        out     (c),l                   ; APT: LX, the first pixel's x, for clipping
        inc     b
        out     (c),h
        ld      bc,DMX2_BPT0_P
        ld      hl,(y0)
        out     (c),l                   ; BPT: LY, its y
        inc     b
        out     (c),h
        ret

neghl:  xor     a                       ; HL = -HL
        sub     l
        ld      l,a
        sbc     a,a
        sub     h
        ld      h,a
        ret

; setclip: the 8 bytes at HL into CLIPXMIN ... CLIPYMAX (ports in a row)
setclip:
        ld      bc,CLIPXMIN_P
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      (high CLIPXMIN_P) + 8
        jr      nz,.next
        ret

box:    dw      30, 329, 16, 239        ; XMIN, XMAX, YMIN, YMAX, inclusive
whole:  dw      -32768, 32767, -32768, 32767

; t0: save TIME's low 16 bits; t1: HL = TIME now - that
t0:     ld      bc,TIME0_P
        in      e,(c)                   ; reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      (t0time),de
        ret
t1:     ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ld      de,(t0time)
        or      a
        sbc     hl,de
        ret

x0:     dw      0
y0:     dw      0
x1:     dw      0
y1:     dw      0
adx:    dw      0
lw:     dw      0
lh:     dw      0
lctrl:  db      0
col:    db      0
ptr:    dw      0
t0time: dw      0
tray:   dw      0
tline:  dw      0
tset:   dw      0

; The rays' far ends: 12 along each side of the screen, all beyond the
; clip rectangle
ends:
k = 0
        DUP     12
        dw      30 * k, 0               ; top, left to right
k = k + 1
        EDUP
k = 0
        DUP     12
        dw      359, 22 * k             ; right, downwards
k = k + 1
        EDUP
k = 0
        DUP     12
        dw      359 - 30 * k, 255       ; bottom, right to left
k = k + 1
        EDUP
k = 0
        DUP     12
        dw      0, 255 - 22 * k         ; left, upwards
k = k + 1
        EDUP
ends_end:

; The patterned lines: the pattern, then y0
dashes: dw      0xFFFF
        dw      250                     ; solid
        dw      0xFF00
        dw      258                     ; long dashes
        dw      0xF0F0
        dw      266                     ; short dashes
        dw      0xFF18
        dw      274                     ; dash and dot
dashes_end:

        align   4
; The fields every line shares; each line then writes CTRL0, APT, BPT, DPT,
; WIDTH and HEIGHT
linejob:
        db      OP_LINE, BPP8, 0        ; CTRL: LINE, 8 bpp (CTRL0 changes per line)
        db      0xCA                    ; MINTERM: A ? B : C, the colour where the pattern is 1
        d24     0, 0, 0                 ; APT (LX), BPT (LY), DPT: per line
        d24     0                       ; WIDTH: per line
        dw      0                       ; HEIGHT: per line
        dw      0                       ; SHIFT: DBIT 0 at 8 bpp
        dw      0                       ; ABSTRIDE: not used
        dw      ROW                     ; CDSTRIDE: the screen's row length
        dd      0xFFFF0000              ; VALUE: a solid pattern; the colour per line
        d24     0                       ; NEXT: none
        db      0

; Black, then a 1-pixel frame just outside the clip rectangle, in a list
clsjob: db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN
        d24     ROW
        dw      288, 0, 0, ROW
        dd      0                       ; black
        d24     .top
        db      0
.top:   db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 15 * ROW + 29
        d24     302                     ; x = 29 to 330
        dw      1, 0, 0, ROW
        dd      0x07070707              ; white
        d24     .bottom
        db      0
.bottom: db     OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 240 * ROW + 29
        d24     302
        dw      1, 0, 0, ROW
        dd      0x07070707
        d24     .left
        db      0
.left:  db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 16 * ROW + 29
        d24     1                       ; y = 16 to 239
        dw      224, 0, 0, ROW
        dd      0x07070707
        d24     .right
        db      0
.right: db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 16 * ROW + 330
        d24     1
        dw      224, 0, 0, ROW
        dd      0x07070707
        d24     0
        db      0

        include "screen.inc"
