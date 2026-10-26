; Copper and CPU palette writes interleaved (ticket #32; spec 6, open point
; C14): each master has its own PALIDX, PALDAT byte counter and colour
; assembly buffer, so the CPU's and the copper's writes to PALDAT can come
; in any order and both colours come out whole. Runs in place of the boot
; ROM (tb.v +rom=coppal.hex) and prints "PASS" or "FAIL nn".
;
;   copper  PALIDX = 0x020, PALDAT blue 0x11, green 0x22, STOP     (list 1)
;   CPU     PALIDX = 0x030, PALDAT blue 0x44, green 0x55
;   copper  PALDAT red 0x33, STOP                                  (list 2)
;   CPU     PALDAT red 0x66
; then entry 0x020 must be 33 22 11 and entry 0x030 66 55 44, the CPU's
; PALIDX 0x031, and the copper's PALIDX 0x021 (it writes on to entry
; 0x021 with a third list).

        DEVICE  NOSLOT64K
        include "hw.inc"
        include "copper.inc"

LIST    equ     0xD000                  ; window 6: SRAM page 4, physical 0x009000
LIST_P  equ     0x009000

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

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        ld      hl,lists                ; the lists into SRAM
        ld      de,LIST
        ld      bc,lists_end - lists
        ldir
        WREG    COP1LC0_P, low (LIST_P + l1 - lists)
        WREG    COP1LC1_P, high (LIST_P + l1 - lists)
        WREG    COP1LC2_P, (LIST_P + l1 - lists) >> 16
        WREG    COP2LC0_P, low (LIST_P + l2 - lists)
        WREG    COP2LC1_P, high (LIST_P + l2 - lists)
        WREG    COP2LC2_P, (LIST_P + l2 - lists) >> 16
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_COPEN_M
        WREG    COPCON_P, COPCON_EN_M

        ; ---- check 1: the copper's blue and green, then the CPU's
        ld      d,1
        WREG    COPJMP1_P, 0
        call    cwait
        WREG    PALIDX0_P, 0x30
        WREG    PALIDX1_P, 0
        WREG    PALDAT_P, 0x44
        WREG    PALDAT_P, 0x55
        ; ---- check 2: the copper's red between the CPU's green and red
        ld      d,2
        WREG    COPJMP2_P, 0
        call    cwait
        WREG    PALDAT_P, 0x66
        RCHK    PALIDX0_P, 0x31         ; the CPU's index stepped by its red only
        ; ---- check 3: both entries whole
        ld      d,3
        WREG    PALIDX0_P, 0x20
        RCHK    PALDAT_P, 0x11
        RCHK    PALDAT_P, 0x22
        RCHK    PALDAT_P, 0x33
        ld      d,4
        RCHK    PALDAT_P, 0x00          ; entry 0x021: not written yet
        RCHK    PALDAT_P, 0x00
        RCHK    PALDAT_P, 0x00
        ld      d,5
        WREG    PALIDX0_P, 0x30
        RCHK    PALDAT_P, 0x44
        RCHK    PALDAT_P, 0x55
        RCHK    PALDAT_P, 0x66
        ; ---- check 6: the copper's index went on to 0x021 by itself,
        ; though the CPU wrote PALIDX meanwhile
        ld      d,6
        WREG    PALIDX0_P, 0x30         ; the CPU's byte counter at blue
        WREG    COP2LC0_P, low (LIST_P + l3 - lists)
        WREG    COP2LC1_P, high (LIST_P + l3 - lists)
        WREG    COPJMP2_P, 0
        call    cwait
        WREG    PALDAT_P, 0x77          ; the CPU's blue: not the copper's
        WREG    PALIDX0_P, 0x21
        RCHK    PALDAT_P, 0x88
        RCHK    PALDAT_P, 0x99
        RCHK    PALDAT_P, 0xAA
        WREG    COPCON_P, 0
        ld      hl,pass
        call    puts
        jr      stop

; Wait until the copper has stopped (COPSTAT.STOPPED, ERR clear)
cwait:  ld      bc,COPSTAT_P
.w:     in      a,(c)
        bit     COPSTAT_STOPPED_B,a
        jr      z,.w
        and     COPSTAT_ERR_M
        jp      nz,fail
        ret

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

puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts
puthex: push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a,'0'
        cp      '9' + 1
        jr      c,putc
        add     a,'A' - '9' - 1
putc:   push    bc
        ld      c,a
.wait:  ld      a,SERSTAT0
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait
        ld      a,c
        out     (SERDATA_PORT),a
        pop     bc
        ret

pass:      db   "PASS", 13, 10, 0
failmsg:   db   "FAIL ", 0

        ALIGN   2
lists:
l1:     CMOVE   PALIDX0, 0x20
        CMOVE   PALIDX1, 0
        CMOVE   PALDAT, 0x11
        CMOVE   PALDAT, 0x22
        CSTOP
l2:     CMOVE   PALDAT, 0x33
        CSTOP
l3:     CMOVE   PALDAT, 0x88            ; entry 0x021, where its index stepped to
        CMOVE   PALDAT, 0x99
        CMOVE   PALDAT, 0xAA
        CSTOP
lists_end:
