; The screen for the blitter examples (docs/guide/blitter.md). It borrows
; layer L0 from the console: it saves L0's 32 registers, makes L0 a
; 360 x 288 bitmap at physical SCREEN, shown at 2x across and down over the
; whole picture, and puts the console back at the end. Channel 2 draws.
; The examples run in the boot ROM's program map, where a Z80 address in
; 0x2000-0xFFFF is its own physical address, so a job's address goes into
; NEXT and CHDESC as it is.

SCREEN  equ     0x040000                ; physical: SRAM page 0x020, free in the program map

BPP1    equ     0                       ; CTRL1: bits per pixel (the layer's BPP codes are the same)
BPP2    equ     1
BPP4    equ     2
BPP8    equ     3
DESC    equ     DMX_CTRL_DESC_M >> 8    ; 0x04  run backwards
IRQ     equ     DMX_CTRL_IRQ_M >> 8     ; 0x08  interrupt when this job ends
BCONST  equ     DMX_CTRL_BCONST_M >> 8  ; 0x10  B is VALUE, not memory
MASKIMG equ     1 << 5                  ; 0x20  A is a 1 bpp mask image
MASKKEY equ     2 << 5                  ; 0x40  A is "B is not the key colour"
OP_BLIT equ     0                       ; CTRL0
OP_ADD  equ     1
OP_LINE equ     2
OP_EDGES equ    3

; scr_on: show L0 as a bitmap of A bits per pixel (0-3), HL bytes a row
scr_on: push    af
        push    hl
        ld      hl,console              ; save the console's L0 registers
        ld      bc,L0_CTRL0_P
.save:  in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        ld      a,b
        cp      (high L0_CTRL0_P) + 32
        jr      nz,.save
        pop     hl
        pop     af
        add     a,a
        add     a,a                     ; BPP into bits 3-2
        or      L_CTRL0_EN_M | (1 << L_CTRL0_HSCALE_B)
        ld      bc,L0_CTRL0_P
        out     (c),a                   ; on, bitmap, opaque, 2x across
        inc     b
        ld      a,1 << L_CTRL1_VSCALE_B
        out     (c),a                   ; CTRL1: 2x down, PALOFS 0
        xor     a
        inc     b
        out     (c),a                   ; CTRL2
        inc     b
        out     (c),a                   ; CTRL3
        ld      de,win
        ld      a,8 + 4                 ; WINX, WINY, SCROLLX, SCROLLY
.win:   ex      af,af'
        inc     b
        ld      a,(de)
        out     (c),a
        inc     de
        ex      af,af'
        dec     a
        jr      nz,.win
        ld      bc,L0_BPLSTRIDE0_P
        out     (c),l
        inc     b
        out     (c),h
        call    scr_pt
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BPLEN_M | DMACON_BLTEN_M
        out     (c),a                   ; the blitter on
        ret

win:    dw      864, 144                ; WINX: XEND, XSTART (the whole picture)
        dw      625, 49                 ; WINY: YEND, YSTART
        dw      0, 0                    ; SCROLLX, SCROLLY

; scr_pt: point L0 at the screen's first line again
scr_pt: ld      bc,L0_BPL0PT0_P
        ld      a,SCREEN & 0xFF
        out     (c),a
        inc     b
        ld      a,(SCREEN >> 8) & 0xFF
        out     (c),a
        inc     b
        ld      a,SCREEN >> 16
        out     (c),a
        ret

; frame: wait for the vertical blank, then point L0 at the screen again
; (nothing resets a bitmap's pointer at the frame start)
frame:  ld      bc,VIDSTAT_P
.vb:    in      a,(c)
        and     VIDSTAT_VBLANK_M
        jr      z,.vb
        out     (c),a                   ; W1C: clear VBLANK
        jr      scr_pt

; waitkey: keep the picture up until a key is pressed
waitkey:
        call    frame
        rst     20h                     ; POLLC: NZ if a key was waiting
        jr      z,waitkey
        ret

; scr_off: the console's L0 back, the blitter off, channel 2's flags clear
scr_off:
        ld      hl,console + 31
        ld      bc,L0_CTRL0_P + 31 * 0x100
.put:   ld      a,(hl)                  ; last register first, CTRL0 (the mode) last
        out     (c),a
        dec     hl
        dec     b
        ld      a,b
        cp      (high L0_CTRL0_P) - 1
        jr      nz,.put
        ld      bc,DMACON_P
        ld      a,DMACON_BLTEN_M        ; SETCLR 0: clear BLTEN
        out     (c),a
        ld      bc,DMX2_CHSTAT_P
        ld      a,DMX_CHSTAT_DONE_M | DMX_CHSTAT_ERR_M
        out     (c),a                   ; W1C
        ret

console:
        ds      32                      ; L0's registers as the console had them

; wait2: wait until channel 2 is idle; A = its CHSTAT
wait2:  ld      bc,DMX2_CHSTAT_P
.busy:  in      a,(c)
        rra                             ; BUSY into carry
        jr      c,.busy
        rla
        ret

; load2: copy the 32-byte job at HL into channel 2's registers (it is idle)
load2:  ld      bc,DMX2_P               ; B = the first register, C = page 0x11
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b                       ; the next register
        ld      a,b
        cp      (high DMX2_P) + 32
        jr      nz,.next
        ret

; run2: run the job at HL on channel 2 and wait for it; A = CHSTAT
run2:   call    wait2
        call    load2
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a                   ; go
        jr      wait2

; start2: run the list whose first descriptor is at HL on channel 2
start2: ld      bc,DMX2_CHDESC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        xor     a                       ; bits 23-16: the program is below 0x10000
        out     (c),a
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_START_M
        out     (c),a
        ret
