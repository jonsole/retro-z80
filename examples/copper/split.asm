; Example 5-5 (docs/guide/copper.md): a split screen. The console's top
; 15 rows stay still; from beam line 337, row 15, the copper scrolls the
; layer sideways, a pixel further every frame, with no help from the CPU.
; It keeps the scroll in COPR1 (bits 7-0) and COPR2 (bits 9-8) from frame
; to frame. The console's map is 128 tiles, 1,024 pixels, across, so the
; scroll wraps at 1,024 without a jump. A key ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

SPLIT   equ     337                     ; the console's row 15: 97 + 15 x 16

start:  ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,COPR0_P+(1<<8)       ; COPR1, COPR2: the scroll starts at 0
        out     (c),a
        inc     b
        out     (c),a
        ld      hl,split
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
        ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M
        out     (c),a

        ld      hl,title
        rst     0x18                    ; PUTS
        ld      b,16                    ; 16 lines of text, over the split
.text:  push    bc
        ld      hl,ruler
        rst     0x18
        pop     bc
        djnz    .text
.main:  rst     0x20                    ; POLLC
        jr      z,.main

        ld      bc,DMACON_P             ; the copper off
        ld      a,DMACON_COPEN_M
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,L0_SCROLLX0_P        ; and the scroll it left behind
        out     (c),a
        inc     b
        out     (c),a
        ret

title:  db      13, 10, "Rows 15 and down scroll; the rows above stay. A key ends it.", 13, 10, 0
ruler:  db      "0123456789 0123456789 0123456789 0123456789 0123456789 0123", 13, 10, 0

        ALIGN   2
split:  CMOVE   L0_SCROLLX0,0           ; the top: no scroll (in the vertical blank)
        CMOVE   L0_SCROLLX1,0
        CLD     CX,CR1                  ; this frame's scroll: last frame's + 1
        CLD     CY,CR2
        CADDI   CX,1
        CSKIPHS                         ; no carry: skip
        CADDI   CY,1                    ; carry into bits 9-8
        CANDI   CY,3                    ; wrap at 1,024
        CST     CR1,CX                  ; kept for the next frame
        CST     CR2,CY
        CWAIT   SPLIT-1,0               ; SCROLLX is taken at the start of each line:
        CMOVR   L0_SCROLLX0,CX          ; write it during the line before
        CMOVR   L0_SCROLLX1,CY
        CSTOP
