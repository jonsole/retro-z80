; Interrupt test ROM (ticket #16): the interrupt controller (spec 8) on the
; whole machine, with tv80's own acknowledge cycles. Runs in place of the
; boot ROM (tb.v +rom=inttest.hex) and prints "PASS" or "FAIL nn" (the
; number of the first check that failed, in hex). tb.v checks every
; acknowledge on the way: one vector request and one int_ack each, and the
; vector at di in time (spec 1, section 8.1, B11).
;
; Covered: the registers' reset values; INTENA set/clear; INTRAW and INTPEND
; with INTENA and MASTER; SOFTINT; IM 2 vectors with three VECBASE values
; (one wrapping round the page); a request held off by MASTER or INTENA
; taken once allowed; a handler that does not clear its source entered
; again; IM 1 with INTID; IM 2 at 3.57 MHz and at 2.5 MHz; VIDINTEN, and a
; real VBLANK taken before SOFT (priority). The VBLANK comes at the end of
; the first frame, about 18 ms in. A spurious acknowledge and the frozen
; choice cannot be made from software at this timing; sim/intc covers them.
;
; Every handler writes the source it was given (INTID, or 0xEE for a wrong
; vector) to a log in SRAM; each check compares the log with what it should
; hold.

        DEVICE  NOSLOT64K
        include "hw.inc"

LOG     equ     0x8000                  ; SRAM page 2 (window 4)
LOGP    equ     0x80F0                  ; the next free byte of the log
KEEP    equ     0x80F2                  ; SOFT handler: times to leave SOFT raised
TABLE   equ     0x8100                  ; IM 2 table: I = 0x81, VECBASE the low byte

    MACRO WREG xp, xv                   ; write xv to register port xp (A, B, C changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    MACRO RCHK xp, xv                   ; fail check D unless register port xp reads xv
        ld      bc,xp
        in      a,(c)
        cp      xv
        jp      nz,fail
    ENDM
    MACRO LCHK xl                       ; fail check D unless the log holds list xl
        ld      hl,xl
        call    chklog
        jp      nz,fail
    ENDM
    MACRO TAKE                          ; let interrupts in for two instructions
        ei
        nop
        nop
        di
    ENDM

        ORG     0x0000

reset:  di
        jp      start

        ds      0x38 - $, 0xFF
        jp      isr38                   ; IM 1

start:  ld      sp,0x0000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    VIDCON_P, VIDCON_EN_M   ; the beam on: the first VBLANK is at the end of this frame
        ld      a,high TABLE
        ld      i,a
        xor     a
        ld      (KEEP),a
        call    logclr

        ; ---- reset values (section 12)
        ld      d,1                     ; check 1
        RCHK    INTCON_P, 0
        RCHK    INTENA0_P, 0
        RCHK    INTENA1_P, 0
        RCHK    INTENA2_P, 0
        RCHK    INTPEND0_P, 0
        RCHK    INTRAW2_P, 0
        RCHK    VECBASE_P, 0
        RCHK    INTID_P, 0
        RCHK    NMICON_P, NMICON_BUTTONEN_M | NMICON_USBEN_M
        RCHK    NMISTAT_P, 0
        RCHK    SOFTINT_P, 0
        RCHK    0x0F00, 0xFF            ; register 0x0F: reserved
        ld      a,INTID                 ; IN A,(n) with A = the register
        in      a,(SYSPAGE)
        or      a
        jp      nz,fail

        ; ---- INTENA: set/clear, each byte alone, bit 7 reads 0
        ld      d,2                     ; check 2
        WREG    INTENA1_P, INTENA_SETCLR_M | 0x7F
        RCHK    INTENA1_P, 0x7F
        WREG    INTENA1_P, 0x55         ; clear 6, 4, 2, 0
        RCHK    INTENA1_P, 0x2A
        RCHK    INTENA0_P, 0
        RCHK    INTENA2_P, 0
        WREG    INTENA1_P, 0x7F
        RCHK    INTENA1_P, 0

        ; ---- SOFTINT: INTRAW2 bit 4; INTPEND needs INTENA and MASTER
        ld      d,3                     ; check 3
        WREG    SOFTINT_P, SOFTINT_SET_M
        RCHK    INTRAW2_P, 1 << INTB_SOFT
        RCHK    INTPEND2_P, 0
        WREG    INTENA2_P, INTENA_SETCLR_M | (1 << INTB_SOFT)
        RCHK    INTPEND2_P, 0
        WREG    INTCON_P, INTCON_MASTER_M
        RCHK    INTPEND2_P, 1 << INTB_SOFT
        RCHK    INTCON_P, INTCON_MASTER_M
        ld      d,4                     ; check 4: CLR clears it
        WREG    SOFTINT_P, SOFTINT_CLR_M
        RCHK    INTRAW2_P, 0
        RCHK    INTPEND2_P, 0

        ; ---- IM 2, held off by MASTER, taken once allowed
        im      2
        xor     a
        call    settab                  ; VECBASE 0x00
        ld      d,5                     ; check 5: MASTER off: not taken
        WREG    INTCON_P, 0
        WREG    SOFTINT_P, SOFTINT_SET_M
        TAKE
        LCHK    exp_none
        ld      d,6                     ; check 6: MASTER on: taken, SOFT's handler
        WREG    INTCON_P, INTCON_MASTER_M
        TAKE
        LCHK    exp_soft
        RCHK    INTRAW2_P, 0            ; the handler cleared it

        ; ---- held off by INTENA, with the source raised
        ld      d,7                     ; check 7: INTENA off: not taken
        call    logclr
        WREG    INTENA2_P, 1 << INTB_SOFT
        WREG    SOFTINT_P, SOFTINT_SET_M
        TAKE
        LCHK    exp_none
        RCHK    INTRAW2_P, 1 << INTB_SOFT
        ld      d,8                     ; check 8: INTENA on again: taken at once
        WREG    INTENA2_P, INTENA_SETCLR_M | (1 << INTB_SOFT)
        TAKE
        LCHK    exp_soft

        ; ---- other VECBASE values
        ld      d,9                     ; check 9: VECBASE 0xD0, SOFT at 0xF4
        call    logclr
        ld      a,0xD0
        call    softim2
        ld      d,10                    ; check 10: VECBASE 0xF0 wraps: SOFT at 0x14
        call    logclr
        ld      a,0xF0
        call    softim2
        RCHK    VECBASE_P, 0xF0
        ld      d,11                    ; check 11: INTID holds the last source
        RCHK    INTID_P, INT_SOFT

        ; ---- level-sensitive: not cleared, entered again after EI
        ld      d,12                    ; check 12: SOFT left raised twice: 3 entries
        call    logclr
        ld      a,2
        ld      (KEEP),a
        WREG    SOFTINT_P, SOFTINT_SET_M
        ei
        nop
        nop
        nop
        nop
        di
        LCHK    exp_soft3

        ; ---- IM 1: RST 38h, the handler reads INTID
        ld      d,13                    ; check 13
        call    logclr
        im      1
        WREG    SOFTINT_P, SOFTINT_SET_M
        TAKE
        LCHK    exp_im1
        im      2

        ; ---- IM 2 at other speeds
        ld      d,14                    ; check 14: 3.57 MHz
        call    logclr
        WREG    CPUSPEED_P, CPUSPEED_SPECTRUM_M
        xor     a
        call    softim2
        ld      d,15                    ; check 15: 2.5 MHz (DIV = 7)
        call    logclr
        WREG    CPUSPEED_P, 7
        xor     a
        call    softim2
        WREG    CPUSPEED_P, 0

        ; ---- VBLANK (spec 4): VIDINTEN, the request line, priority
        ld      d,16                    ; check 16: VIDINTEN at reset, bit 3 reserved
        RCHK    VIDINTEN_P, 0
        WREG    VIDINTEN_P, 0xFF
        RCHK    VIDINTEN_P, 0xF7
        WREG    VIDINTEN_P, 0
        ld      d,17                    ; check 17: the flag alone does not request
        ld      bc,VIDSTAT_P
.vb:    in      a,(c)
        and     VIDSTAT_VBLANK_M
        jr      z,.vb                   ; the start of the next frame
        RCHK    INTRAW0_P, 0
        ld      d,18                    ; check 18: flag AND VIDINTEN.VBLANK requests
        WREG    VIDINTEN_P, VIDINTEN_VBLANK_M
        RCHK    INTRAW0_P, 1 << INTB_VBLANK
        RCHK    INTPEND0_P, 0
        ld      d,19                    ; check 19: VBLANK (0) before SOFT (18)
        call    logclr
        xor     a
        call    settab
        WREG    SOFTINT_P, SOFTINT_SET_M
        WREG    INTENA0_P + (INTR_VBLANK << 8), INTENA_SETCLR_M | (1 << INTB_VBLANK)
        RCHK    INTPEND0_P, 1 << INTB_VBLANK
        TAKE
        LCHK    exp_vbl
        ld      d,20                    ; check 20: the handler cleared VIDSTAT.VBLANK
        RCHK    INTRAW0_P, 0
        ld      bc,VIDSTAT_P
        in      a,(c)
        and     VIDSTAT_VBLANK_M        ; (INVBLANK is live, and set here)
        jp      nz,fail

        ld      hl,pass
        call    puts
        jr      stop

fail:   ld      hl,failmsg
        call    puts
        ld      a,d
        call    puthex
        ld      a,13
        call    putc
        ld      a,10
        call    putc
stop:   di
        halt
        jr      stop

; IM 2 with VECBASE = A: SOFT raised and taken once by its own handler
; (fails check D otherwise)
softim2:
        call    settab
        WREG    SOFTINT_P, SOFTINT_SET_M
        TAKE
        LCHK    exp_soft
        ret

; VECBASE = A; the table full of hbad but for VBLANK's and SOFT's entries
settab: ld      bc,VECBASE_P
        out     (c),a
        ld      e,a
        ld      hl,TABLE
        ld      b,128
.fill:  ld      (hl),hbad & 0xFF
        inc     hl
        ld      (hl),hbad >> 8
        inc     hl
        djnz    .fill
        ld      h,high TABLE
        ld      l,e                     ; VBLANK: VECBASE + 0
        ld      (hl),hgood & 0xFF
        inc     l
        ld      (hl),hgood >> 8
        ld      a,e
        add     a,2 * INT_SOFT          ; SOFT: VECBASE + 36, round the page
        ld      l,a
        ld      (hl),hgood & 0xFF
        inc     l
        ld      (hl),hgood >> 8
        ret

; Handlers. hgood (IM 2) and isr38 (IM 1) log INTID (IM 1 with bit 7 set),
; then clear the source INTID names: SOFT (unless KEEP says to leave it
; raised) or VBLANK. hbad, a wrong vector, logs 0xEE and clears both.
hgood:  push    af
        push    bc
        push    hl
        ld      a,INTID
        in      a,(SYSPAGE)
        push    af
        call    logit
        pop     af
        jr      hclear
isr38:  push    af
        push    bc
        push    hl
        ld      a,INTID
        in      a,(SYSPAGE)
        push    af
        or      0x80
        call    logit
        pop     af
hclear: cp      INT_SOFT
        jr      nz,.notsoft
        ld      a,(KEEP)
        or      a
        jr      z,.clrsoft
        dec     a
        ld      (KEEP),a
        jr      hdone
.clrsoft:
        WREG    SOFTINT_P, SOFTINT_CLR_M
        jr      hdone
.notsoft:
        cp      INT_VBLANK
        jr      nz,hdone
        WREG    VIDSTAT_P, VIDSTAT_VBLANK_M
hdone:  pop     hl
        pop     bc
        pop     af
        ei
        reti
hbad:   push    af
        push    bc
        push    hl
        ld      a,0xEE
        call    logit
        WREG    SOFTINT_P, SOFTINT_CLR_M
        WREG    VIDSTAT_P, VIDSTAT_VBLANK_M
        jr      hdone

; The log
logclr: ld      hl,LOG
        ld      (LOGP),hl
        ret
logit:  ld      hl,(LOGP)               ; append A (HL changed)
        ld      (hl),a
        inc     hl
        ld      (LOGP),hl
        ret
; Z if the log holds what HL points at: a count, then the bytes (A, B, DE, HL changed)
chklog: ld      b,(hl)
        inc     hl
        push    hl
        ld      hl,(LOGP)
        ld      de,LOG
        or      a
        sbc     hl,de
        ld      a,l
        pop     hl
        cp      b
        ret     nz
        ld      a,b
        or      a
        ret     z
.cmp:   ld      a,(de)
        cp      (hl)
        ret     nz
        inc     de
        inc     hl
        djnz    .cmp
        xor     a
        ret

; Send A as two hex digits
puthex: push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a,'0'
        cp      '9'+1
        jr      c,putc
        add     a,'A'-'9'-1
        jr      putc

puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts

; Send A over USB (A, B, C changed; the byte is kept in E)
putc:   push    bc
        ld      e,a
.wait:  ld      a,SERSTAT0
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait
        ld      a,e
        out     (SERDATA_PORT),a
        pop     bc
        ret

exp_none:  db   0
exp_soft:  db   1, INT_SOFT
exp_soft3: db   3, INT_SOFT, INT_SOFT, INT_SOFT
exp_im1:   db   1, 0x80 | INT_SOFT
exp_vbl:   db   2, INT_VBLANK, INT_SOFT
pass:      db   "PASS", 13, 10, 0
failmsg:   db   "FAIL ", 0
