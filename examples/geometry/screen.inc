; The screen and the helpers for the geometry examples (docs/guide/geometry.md).
;
; The examples run in the boot ROM's program map with the register page in
; window 7 (SREG, 0xE000: system register r at SREG + r, custom register c at
; CREG + c), as Chapter 1's examples do. The screen is a 256 x 192 bitmap at
; 1 bit per pixel, 32 bytes a row, shown by layer L0 at 2x each way in the
; middle of the picture, in white on black. There are two of them, SRAM
; pages 0x020 and 0x021 (physical 0x040000 and 0x042000): the one being
; drawn is in window 6 (0xC000), and flip shows it at the next vertical
; blank and brings the other into window 6. Lines are drawn by the Z80,
; since the KS2's build with the geometry unit has no blitter.
;
; The console's L0 and its two palette entries are saved and put back.

PG_REGS equ     0x3F8                   ; the register page
SREG    equ     0xE000                  ; the system registers, in window 7
CREG    equ     SREG + REGS_CUSTOM      ; the custom registers
DRAW    equ     0xC000                  ; the screen being drawn, in window 6
PAGE0   equ     0x020                   ; the two screens' SRAM pages
ROW     equ     32                      ; bytes a row
PALOFS  equ     15                      ; the screen's colours: palette entries 240, 241
PALENT  equ     SREG + REGS_PALETTE0 + 3 * 16 * PALOFS
WIN_X   equ     VID_X0 + (VID_W - 512) / 2  ; the window, 512 x 384, centred
WIN_Y   equ     VID_Y0 + (VID_H - 384) / 2

GEO     equ     SREG + GEOW0            ; the geometry unit's window of 12 words
GEO_V   equ     SREG + GEOVX            ; VX0, or RX0 when read
GEO_CTL equ     SREG + GEOCTL
GEO_ST  equ     SREG + GEOSTAT

PUTHEX  equ     0x06                    ; RST 28h functions
PUTHEX16 equ    0x07
PUTDEC  equ     0x08
EXIT    equ     0x0040

; regs_on: the stack below the program's windows, the register page into
; window 7 (through ports: the MMU's registers are in the system page)
regs_on:
        pop     hl                      ; the return address
        ld      sp,0xC000               ; the top of window 5
        push    hl
        ld      hl,PG_REGS
        ld      bc,MMU7_0_P
        out     (c),l
        inc     b
        out     (c),h                   ; from here, 0xE000-0xFFFF are the registers
        ret

; regs_off: window 7 back to SRAM page 7 and the program over; nothing is
; printed after it, so the message is given first
regs_off:
        ld      hl,7
        ld      (SREG + MMU7),hl        ; the last register write
        jp      EXIT

; scr_on: the console's L0 and colours saved; L0 the screen, page 0x020
; shown and page 0x021 in window 6 to draw on; both blank
scr_on: ld      hl,CREG + L0
        ld      de,console
        ld      bc,L_SPAN
        ldir
        ld      hl,PALENT
        ld      de,colours_were
        ld      bc,6
        ldir
        ld      hl,PAGE0                ; both screens blank
        ld      (SREG + MMU6),hl
        call    cls
        ld      hl,PAGE0 + 1
        ld      (SREG + MMU6),hl
        call    cls
        ld      a,1
        ld      (drawing),a             ; drawing on page 0x021
        ld      hl,colours
        ld      de,PALENT
        ld      bc,6
        ldir
        ld      hl,layer                ; L0: the screen, 2 x 2
        ld      de,CREG + L0
        ld      bc,L_SPAN
        ldir
        ret

layer:  db      L_CTRL0_EN_M | (1 << L_CTRL0_HSCALE_B)  ; CTRL0: on, 1 bpp bitmap, 2x across
        db      (1 << L_CTRL1_VSCALE_B) | (PALOFS << L_CTRL1_PALOFS_B)  ; CTRL1: 2x down
        db      0, 0                    ; CTRL2, CTRL3
        dw      WIN_X + 512, WIN_X      ; WINX: XEND, XSTART
        dw      WIN_Y + 384, WIN_Y      ; WINY: YEND, YSTART
        dw      0, 0                    ; SCROLLX, SCROLLY
        dw      ROW                     ; BPLSTRIDE
        dw      0
        d24     PAGE0 * 0x2000          ; BPL0PT: screen 0
        db      0
        d24     0                       ; MAPPT
        db      0
        d24     0                       ; PATPT
        db      0
colours: db     0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF  ; entry 240 black, 241 white (blue, green, red)

; scr_off: the console's L0 and colours back
scr_off:
        ld      hl,colours_were
        ld      de,PALENT
        ld      bc,6
        ldir
        ld      hl,console + L_SPAN - 1 ; the last register first, CTRL0 (the mode) last
        ld      de,CREG + L0 + L_SPAN - 1
        ld      bc,L_SPAN
        lddr
        ld      hl,6                    ; window 6 back to SRAM page 6
        ld      (SREG + MMU6),hl
        ret

console: ds     L_SPAN                  ; L0's registers as the console had them
colours_were: ds 6
drawing: db     0                       ; 0 or 1: the screen in window 6

; cls: the screen in window 6 blank (6,144 bytes; about 6.5 ms)
cls:    ld      hl,DRAW
        ld      de,DRAW + 1
        ld      (hl),0
        ld      bc,ROW * 192 - 1
        ldir
        ret

; flip: at the next vertical blank, show the screen just drawn and bring
; the other into window 6
flip:   ld      hl,CREG + VIDSTAT
.vb:    bit     0,(hl)                  ; VBLANK
        jr      z,.vb
        ld      (hl),VIDSTAT_VBLANK_M   ; W1C: clear it
        ld      a,(drawing)
        ld      h,a
        ld      l,0
        add     hl,hl                   ; page x 0x2000 = screen x 0x20 in bits 15-8 ...
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      (CREG + L0 + L_BPL0PT),hl   ; ... the pointer's low two bytes
        ld      hl,PAGE0 * 0x2000 >> 16
        ld      (CREG + L0 + L_BPL0PT + 2),hl   ; its top byte (and the spare)
        xor     1
        ld      (drawing),a
        ld      l,a
        ld      h,high PAGE0
        ld      a,low PAGE0
        or      l
        ld      l,a
        ld      (SREG + MMU6),hl        ; the other screen into window 6
        ret

; key: NZ if a key has been pressed
key:    rst     20h                     ; POLLC
        ret

; line: from (B, C) to (D, E), x 0-255 and y 0-191, on the screen in
; window 6, in white. Bresenham, a pixel at a time. A line with an end off
; the screen (y > 191) is left out. Uses everything.
line:   ld      a,c
        cp      192
        ret     nc
        ld      a,e
        cp      192
        ret     nc
        ld      a,d                     ; dx = |x1 - x0|, sx = +1 or -1
        sub     b
        ld      (.sx),a                 ; (the sign)
        jr      nc,.xr
        neg
.xr:    ld      h,a
        ld      a,e                     ; dy = |y1 - y0|, sy
        sub     c
        ld      (.sy),a
        jr      nc,.yd
        neg
.yd:    ld      l,a                     ; H = dx, L = dy
        cp      h
        jr      c,.alongx
; along y: dy >= dx. Error starts at dy / 2; each step down, err -= dx;
; below 0, step across and err += dy
        ld      a,l
        or      a
        jr      nz,.y
        jp      plot                    ; a single point
.y:     ld      d,l                     ; D = pixels left, E = error
        ld      e,l
        srl     e
.yloop: call    plot
        ld      a,e
        sub     h
        ld      e,a
        jr      nc,.ynox
        add     a,l
        ld      e,a
        ld      a,(.sx)
        or      a
        jp      m,.yxl
        inc     b
        jr      .ynox
.yxl:   dec     b
.ynox:  ld      a,(.sy)
        or      a
        jp      m,.yup
        inc     c
        jr      .ynext
.yup:   dec     c
.ynext: dec     d
        jp      p,.yloop
        ret
; along x: dx > dy
.alongx:
        ld      d,h                     ; D = pixels left, E = error
        ld      e,h
        srl     e
.xloop: call    plot
        ld      a,e
        sub     l
        ld      e,a
        jr      nc,.xnoy
        add     a,h
        ld      e,a
        ld      a,(.sy)
        or      a
        jp      m,.xyu
        inc     c
        jr      .xnoy
.xyu:   dec     c
.xnoy:  ld      a,(.sx)
        or      a
        jp      m,.xl
        inc     b
        jr      .xnext
.xl:    dec     b
.xnext: dec     d
        jp      p,.xloop
        ret
.sx:    db      0
.sy:    db      0

; plot: the pixel at (B, C) set. Keeps BC, DE, HL.
plot:   push    hl
        push    de
        push    bc
        ld      l,c                     ; row C x 32 ...
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,b                     ; ... + x / 8
        rrca
        rrca
        rrca
        and     31
        or      l
        ld      l,a
        ld      a,h
        add     a,high DRAW
        ld      h,a
        ld      a,b                     ; the bit: 7 - (x and 7)
        and     7
        ld      b,a
        ld      a,0x80
        jr      z,.set
.bit:   rrca
        djnz    .bit
.set:   or      (hl)
        ld      (hl),a
        pop     bc
        pop     de
        pop     hl
        ret

; puts: the string at HL on the console
puts:   rst     18h
        ret

; putsd: HL as a signed decimal on the console
putsd:  bit     7,h
        jr      z,.pos
        ld      a,'-'
        rst     08h
        xor     a
        sub     l
        ld      l,a
        sbc     a,a
        sub     h
        ld      h,a
.pos:   rst     28h
        db      PUTDEC
        ret

; putu: HL as an unsigned decimal
putu:   rst     28h
        db      PUTDEC
        ret

; puthex16: HL as four hex digits
puthex16:
        rst     28h
        db      PUTHEX16
        ret

; crlf
crlf:   ld      a,13
        rst     08h
        ld      a,10
        rst     08h
        ret

; time: HL = TIME's low 16 bits, microseconds (reading TIME0 captures all four)
time:   ld      hl,(SREG + TIME0)
        ret
