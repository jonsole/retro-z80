; The screen for the blitter and rasteriser examples (docs/guide/blitter.md).
; It borrows layer L0 from the console: it saves L0's 32 registers, makes L0
; a 360 x 288 bitmap at physical SCREEN, shown at 2x across and down over
; the whole picture, and puts the console back at the end. It also has the
; routines that start the blitter and the rasteriser and wait for them.
; The examples run in the boot ROM's program map, where a Z80 address in
; 0x2000-0xFFFF is its own physical address, so a descriptor's address goes
; into BLTNEXT, BLTDESC, RASNEXT and RASDESC as it is.

SCREEN  equ     0x040000                ; physical: SRAM page 0x020, free in the program map

; Fields of BLTCTRL and RASCTRL that hw.inc gives only as masks
BPP1    equ     0 << BLTCTRL_BPP_B      ; bits 9-8, in both units: 1 bit a pixel
BPP2    equ     1 << BLTCTRL_BPP_B
BPP4    equ     2 << BLTCTRL_BPP_B
BPP8    equ     3 << BLTCTRL_BPP_B      ; 0x300
MASKIMG equ     1 << BLTCTRL_MASK_B     ; 0x20000  A is the 1 bpp image at BLTAPT (not on the KS2)
MASKKEY equ     2 << BLTCTRL_MASK_B     ; 0x40000  A is 1 where B is not the KEY colour
MT      equ     1 << BLTCTRL_MINTERM_B  ; MINTERM m is m * MT, in both units

; scr_on: show L0 as a bitmap of A bits per pixel (0-3, as the layer's BPP
; codes), HL bytes a row; set DMACON's DMAEN, BPLEN and BLTEN
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
        out     (c),a                   ; the blitter and the rasteriser on
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

; scr_off: wait for both units, then the console's L0 back, BLTEN off and
; DMXINT clear
scr_off:
        call    bltwait
        call    raswait
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
        ld      bc,DMXINT_P
        ld      a,DMXINT_BLT_M | DMXINT_RAS_M
        out     (c),a                   ; W1C
        ret

console:
        ds      32                      ; L0's registers as the console had them

; bltwait: wait until the blitter is idle; A = BLTSTAT
bltwait:
        ld      bc,BLTSTAT_P
.busy:  in      a,(c)
        rra                             ; BUSY into carry
        jr      c,.busy
        rla
        ret

; bltload: copy the 32-byte job at HL into the blitter's job registers
; (it is idle)
bltload:
        ld      bc,BLTCTRL0_P           ; B = the first register, C = 0x11
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b                       ; the next register
        ld      a,b
        cp      (high BLTCTRL0_P) + 32
        jr      nz,.next
        ret

; bltrun: run the job at HL and wait for it; A = BLTSTAT
bltrun: call    bltwait
        call    bltload
        ld      bc,BLTCMD_P
        ld      a,BLTCMD_RUN_M
        out     (c),a                   ; go
        jr      bltwait

; bltstart: start the chain whose first descriptor is at HL (the blitter is idle)
bltstart:
        ld      bc,BLTDESC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        xor     a                       ; bits 23-16: the program is below 0x10000
        out     (c),a
        ld      bc,BLTCMD_P
        ld      a,BLTCMD_START_M
        out     (c),a
        ret

; raswait: wait until the rasteriser is idle; A = RASSTAT
raswait:
        ld      bc,RASSTAT_P
.busy:  in      a,(c)
        rra                             ; BUSY into carry
        jr      c,.busy
        rla
        ret

; rasload: copy the 32-byte job at HL into the rasteriser's job registers
; (it is idle)
rasload:
        ld      bc,RASCTRL0_P
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      (high RASCTRL0_P) + 32
        jr      nz,.next
        ret

; rasstart: start the chain whose first descriptor is at HL (the rasteriser is idle)
rasstart:
        ld      bc,RASDESC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        xor     a
        out     (c),a
        ld      bc,RASCMD_P
        ld      a,RASCMD_START_M
        out     (c),a
        ret

; setclip: the 8 bytes at HL into RASCLIPMIN and RASCLIPMAX (the rasteriser
; is idle): YMIN, XMIN, YMAX, XMAX as words
setclip:
        ld      bc,RASCLIPMIN0_P
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      (high RASCLIPMIN0_P) + 8
        jr      nz,.next
        ret

; t0: note the time (TIME's low 16 bits, in us)
t0:     push    bc
        push    de
        ld      bc,TIME0_P
        in      e,(c)                   ; reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      (t0time),de
        pop     de
        pop     bc
        ret

; t1: HL = the us since t0 (up to 65,535)
t1:     push    bc
        push    de
        ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ld      de,(t0time)
        or      a
        sbc     hl,de
        pop     de
        pop     bc
        ret

t0time: dw      0
