; Example 9-5 (docs/guide/geometry.md): the unit as a calculator. Four
; multiplies and four divides through the operands bank, each printed with
; its result and the status bits that matter: a 32-bit product, a quotient
; with its remainder, a quotient that saturates, and a divide by zero.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  call    regs_on                 ; the register page into window 7
        ld      hl,title
        call    puts
        ld      a,GEO_BANK_OPS          ; the operands bank
        ld      (GEO_CTL),a

; The multiplies: MA, then MB (MB1 last: it starts the job)
        ld      ix,muls
        ld      b,4
.mul:   push    bc
        ld      l,(ix+0)
        ld      h,(ix+1)
        call    putsd
        ld      hl,s_times
        call    puts
        ld      l,(ix+2)
        ld      h,(ix+3)
        call    putsd
        ld      hl,s_is
        call    puts
        ld      l,(ix+0)
        ld      h,(ix+1)
        ld      (GEO + 12),hl           ; MA
        ld      l,(ix+2)
        ld      h,(ix+3)
        ld      (GEO + 14),hl           ; MB: starts the multiply
        ld      hl,(GEO_V+2)            ; RY: the product's bits 31-16
        call    puthex16
        ld      hl,(GEO_V)              ; RX: bits 15-0
        call    puthex16
        call    crlf
        ld      de,4
        add     ix,de
        pop     bc
        djnz    .mul

; The divides: DVD's four bytes, then DVS (DVS1 last: it starts the job)
        ld      ix,divs
        ld      b,4
.div:   push    bc
        ld      l,(ix+2)
        ld      h,(ix+3)
        call    puthex16                ; the dividend, as hex
        ld      l,(ix+0)
        ld      h,(ix+1)
        call    puthex16
        ld      hl,s_over
        call    puts
        ld      l,(ix+4)
        ld      h,(ix+5)
        call    putsd
        ld      hl,s_is
        call    puts
        push    ix
        pop     hl
        ld      de,GEO + 16             ; DVD0-3, then DVS0, DVS1
        ld      bc,6
        ldir                            ; the last byte starts the divide
        ld      hl,(GEO_V)              ; RX: the quotient
        call    putsd
        ld      hl,s_rem
        call    puts
        ld      hl,(GEO_V+2)            ; RY: the remainder
        call    putsd
        ld      a,(GEO_ST)
        ld      c,a
        and     GEOSTAT_DIVZ_M
        jr      z,.nodivz
        ld      hl,s_divz
        call    puts
.nodivz:
        ld      a,c
        and     GEOSTAT_SAT_M
        jr      z,.nosat
        ld      hl,s_sat
        call    puts
.nosat: call    crlf
        ld      de,6
        add     ix,de
        pop     bc
        djnz    .div
        jp      regs_off

muls:   dw      1234, 567               ; 699,678 = 0x000AAD1E
        dw      -1234, 567              ; -699,678 = 0xFFF552E2
        dw      -32768, -32768          ; 1,073,741,824 = 0x40000000: never saturates
        dw      0x4000, 0x2000          ; 1.0 x 0.5 in 2.14: 0x08000000, the answer in bits 29-14
divs:   dd      100000                  ; 100000 / 7 = 14285 remainder 5
        dw      7
        dd      -100000                 ; -100000 / 7 = -14285 remainder -5
        dw      7
        dd      1000000                 ; 1000000 / 3 = 333333: too big, saturates
        dw      3
        dd      1                       ; 1 / 0: DIVZ
        dw      0

title:  db      13, 10, "The geometry unit as a calculator", 13, 10, 0
s_times: db     " x ", 0
s_is:   db      " = ", 0
s_over: db      " / ", 0
s_rem:  db      " remainder ", 0
s_divz: db      "  DIVZ", 0
s_sat:  db      "  SAT", 0

        include "screen.inc"
