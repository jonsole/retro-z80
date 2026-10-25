; Video test ROM (spec 4; tickets #13, #14 and #31): the frame is cut into bands, each
; showing L0 with other settings (depth, scale, window, fine scroll,
; stride, wrap, TRANSP, PALOFS) over random picture data that vgen.py put
; in the SRAM. vgen.py writes the bands as straight-line code (vbands.inc),
; timed in T-states from the start of each frame, so each band's registers
; are written in the lines between two bands, with the layer off. The
; testbench (tb.v +frame=G) logs every write to the video unit with the
; beam position and grabs a frame; vmodel.py replays the writes and checks
; every pixel.
;
; Before the beam starts, the palettes get random colours: PALETTE0
; entries 0-127 through PALIDX and PALDAT, 128-255 through the register
; page, then 32 entries through PALDAT from PALETTE0's entry 240 on, so the
; index steps on into PALETTE1, and SPRPALETTE's first entries through the
; register page (the model checks L0 uses PALETTE0 only).
;
; The sprite screens (ticket #31; vgen.py s, h and q) use the same frame
; code: vbands.inc writes L0 and every sprite's registers in the vertical
; blank (CTL last), then changes sprites, L0 and PRIO at set lines while
; they are drawn; setup writes the rest of SPRPALETTE.
;
; Assemble: sjasmplus -I firmware/include -I <dir of vbands.inc> --raw=vtest.bin vtest.asm

        DEVICE  NOSLOT64K
        include "hw.inc"

W3      equ     0x6000                  ; window 3: the register page

        ORG     0x0000
        di
        ld      sp,0x0000               ; stack at the top of window 7 (SRAM page 5)
        ld      bc,SERCON_P
        ld      a,SERCON_EN_M | SERCON_TXDROP_M
        out     (c),a

        ; ---- palettes
        ld      bc,PALIDX0_P            ; PALIDX = 0: PALETTE0, entry 0
        xor     a
        out     (c),a
        inc     b
        out     (c),a
        ld      b,PALDAT
        ld      hl,paltab
        ld      de,128*3
        call    stream
        ld      bc,MMU3_0_P             ; window 3: the register page
        ld      a,0xF8
        out     (c),a
        inc     b
        ld      a,0x03
        out     (c),a
        ld      de,W3+REGS_PALETTE0+128*3
        ld      bc,128*3
        ldir                            ; blue, green, red: rising addresses
        ld      bc,PALIDX0_P            ; PALIDX = 240
        ld      a,240
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      b,PALDAT
        ld      de,32*3                 ; 240-255, then PALETTE1 0-15
        call    stream
        ld      de,W3+REGS_SPRPALETTE
        ld      bc,16*3
        ldir
        call    setup                   ; the variant's own (vbands.inc): the sprite screens' SPRPALETTE

        ; ---- the rest: background, fetch on, beam on
        ld      hl,bgtab
        ld      bc,BGCOLOR0_P
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BPLEN_M | DMACON_SPREN_M
        out     (c),a
        ld      bc,VIDCON_P
        ld      a,VIDCON_VAL            ; vbands.inc: EN, and SHAREPAL for one sprite screen
        out     (c),a

        ld      hl,0x8000               ; dly's SRAM byte: window 4, SRAM page 2
        ld      (hl),0                  ; defined, so dly never writes back an unknown value

        ; ---- each frame: wait for its start, then the bands
frame:  ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a                   ; clear VBLANK
.vb:    in      a,(c)
        rrca
        jr      nc,.vb                  ; 28 T-states a turn
        call    bands
        jr      frame

; OUT (C) the DE bytes at HL, B and C fixed (HL, DE, A changed)
stream: ld      a,(hl)
        out     (c),a
        inc     hl
        dec     de
        ld      a,d
        or      e
        jr      nz,stream
        ret

; Wait 40 x DE + 5 T-states, with the RET (DE >= 1; A changed). With its
; LD DE,nn and CALL: 40 x DE + 32. Each turn reads and writes the SRAM at
; HL, so the Z80 uses the memory all through the frame while the display
; fetches (the testbench checks that it never waits)
dly:    ld      a,(hl)                  ;  7
        ld      (hl),a                  ;  7
        dec     de                      ;  6
        ld      a,d                     ;  4
        or      e                       ;  4
        jr      nz,dly                  ; 12, 7 the last time
        ret                             ; 10

        include "vbands.inc"            ; bands: the band code; paltab, bgtab: data
