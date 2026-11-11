; Rasteriser test (spec 19; retro-hw's raster core). retro68k's
; sim/rastest/rastest.s (raster, d77ddd5) on the Z80.
;
; The random part: rgen.py puts random data, descriptors and a control
; table in the SRAM; this program runs the chains one after another, each
; under its own clip window, checks that none stopped with an error and
; that each set DMXINT.RAS at its end. The testbench dumps the SRAM at the
; end (+ramout) and rmodel.py checks every byte. Lines and triangles at
; every depth, stride sign and minterm class are among rgen.py's jobs.
;
; Then directed tests, checked here: the registers and the window read
; back, a line by RUN (the spec's worked example), the pattern, NOLAST and
; the window, a triangle by START (the worked example), a chain with and
; without IRQ on its first job, the reserved-bit error alone and in a
; chain, writes while busy, STOP, BLTEN, the interrupt request, the
; blitter and the rasteriser running together, and the copper's WAIT B.
;
; Prints PASS, or FAIL nn: 1c the chain c'th from the end stopped with an
; error, 2c it did not set DMXINT; 30-FF a directed check (the high digit
; the test, R1 = 3 ... R13 = F).
;
; The control table (keep in step with rgen.py), physical 0x00A000, Z80
; 0xE000 in the map after reset:
CTL     equ     0xE000                  ; +0: the number of chains; then 44 bytes a chain:
C_LEN   equ     44                      ; RASCLIPMIN, RASCLIPMAX (4 bytes each), the first
                                        ; descriptor (3 bytes and a spare; START), or 0
                                        ; and the first job's 32 bytes (RUN)

        DEVICE  NOSLOT64K
        include "hw.inc"
        include "copper.inc"

; The directed tests' memory: Z80 0xC000-0xDFFF (window 6) is physical
; 0x008000-0x009FFF, outside what rmodel.py checks
BM      equ     0xC000                  ; a bitmap: 16 x 16 pixels, 8 bits each, 16 bytes a row
BM2     equ     0xC100                  ; another, for the triangle
DSC     equ     0xC200                  ; descriptors, 32 bytes each
WIDE    equ     0xC400                  ; one row of 256 pixels, then 4 bytes 0xFF
WARM    equ     0xC600                  ; the blitter's first job's 4 bytes
COPL    equ     0xC700                  ; a copper list
BIG     equ     0xD000                  ; the blitter's 4 KB
PHYS    equ     0xC000 - 0x8000         ; Z80 address - PHYS = physical address
BM_P    equ     BM - PHYS
BM2_P   equ     BM2 - PHYS
DSC_P   equ     DSC - PHYS
WIDE_P  equ     WIDE - PHYS
WARM_P  equ     WARM - PHYS
COPL_P  equ     COPL - PHYS
BIG_P   equ     BIG - PHYS

nleft   equ     0xBF00                  ; chains still to run (window 5, SRAM)

R8BPP   equ     0x0300                  ; RASCTRL: BPP 3, 8 bits a pixel
RTRI    equ     0x10000
RIRQ    equ     0x1000
RNOLAST equ     0x20000
MT      equ     0x1000000               ; MINTERM x: x * MT
LINE8   equ     0xCC*MT | R8BPP         ; D = the colour, 8 bpp; add the colour
TRI8    equ     LINE8 | RTRI
FAR     equ     30000                   ; a line's end far outside the window: 300 us of stepping
B8      equ     0x0300                  ; BLTCTRL: 8 bpp
BCONST  equ     0x2000

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
    MACRO RBIT xp, xm, xv               ; fail check D unless (port xp AND xm) is xv
        ld      bc,xp
        in      a,(c)
        and     xm
        cp      xv
        jp      nz,fail
    ENDM
    MACRO MCHK xa, xv                   ; fail check D unless the byte at xa is xv
        ld      a,(xa)
        cp      xv
        jp      nz,fail
    ENDM
    ; A rasteriser job, as the job registers and a descriptor: RASCTRL,
    ; RASP0-RASP2 (Y then X), RASDPT, RASSTRIDE, RASPAT, RASNEXT
    MACRO RJOB rctl, rx0, ry0, rx1, ry1, rx2, ry2, rdpt, rstr, rpat, rnxt
        dd      rctl
        dw      (ry0) & 0xFFFF, (rx0) & 0xFFFF
        dw      (ry1) & 0xFFFF, (rx1) & 0xFFFF
        dw      (ry2) & 0xFFFF, (rx2) & 0xFFFF
        dd      rdpt
        dd      (rstr) & 0xFFFF
        dd      rpat
        dd      rnxt
    ENDM
    ; A blitter job: BLTCTRL, BLTBPT, BLTDPT, BLTSIZE, BLTAPT, BLTSTRIDE,
    ; BLTVALUE, BLTNEXT
    MACRO BJOB ctl, bpt, dpt, wid, hgt, apt, dstr, bstr, val, astr, nxt
        dd      ctl, bpt, dpt
        dw      wid, hgt
        dd      apt
        dw      dstr, bstr, val, astr
        dd      nxt
    ENDM

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M
        WREG    DMXINTEN_P, DMXINTEN_BLT_M | DMXINTEN_RAS_M

        ; ================================================ the random chains
        ld      a,(CTL)
        ld      (nleft),a
        ld      hl,CTL + 4
.chain: push    hl                      ; the entry
        ld      bc,RASCLIPMIN_P         ; the window: RASCLIPMIN, RASCLIPMAX
        ld      e,8
        call    outs
        ld      a,(hl)                  ; a descriptor address, or 0
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        dec     hl
        dec     hl
        jr      z,.run
        ld      bc,RASDESC0_P           ; a chain in the SRAM: RASDESC, START
        ld      e,3
        call    outs
        WREG    RASCMD_P, RASCMD_START_M
        jr      .wait
.run:   inc     hl                      ; the first job into the job registers, RUN
        inc     hl
        inc     hl
        inc     hl
        ld      bc,RASCTRL_P
        ld      e,32
        call    outs
        WREG    RASCMD_P, RASCMD_RUN_M

.wait:  call    waitr                   ; the chain's end
        ld      e,a
        ld      a,(nleft)
        or      0x10
        ld      d,a
        bit     RASSTAT_ERR_B,e
        jp      nz,fail                 ; FAIL 1c: an error
        add     a,0x10
        ld      d,a
        RBIT    DMXINT_P, DMXINT_RAS_M, DMXINT_RAS_M    ; FAIL 2c: no DMXINT
        WREG    DMXINT_P, DMXINT_RAS_M  ; cleared (write 1)
        pop     hl
        ld      bc,C_LEN
        add     hl,bc
        ld      a,(nleft)
        dec     a
        ld      (nleft),a
        jr      nz,.chain

        ; ================================================ directed tests
        ld      hl,BM                   ; the bitmaps cleared
        ld      bc,0x200
        call    zero
        ld      hl,descs                ; the descriptors into the SRAM
        ld      de,DSC
        ld      bc,6*32
        ldir

        ; ---- R1: the job registers read back (reserved bits read 0, also
        ; RASCTRL's), a byte written on its own; RASDESC; the clip window
        ld      d,0x30
        ld      hl,j_regs
        ld      bc,RASCTRL_P
        ld      e,32
        call    outs
        ld      hl,x_regs
        ld      bc,RASCTRL_P
        ld      e,32
        call    ins
        ld      d,0x31
        WREG    RASP1_1_P, 0x5A
        RCHK    RASP1_0_P, 0xF0
        RCHK    RASP1_1_P, 0x5A
        RCHK    RASP1_2_P, 0xBC
        ld      d,0x32                  ; RASDESC: bits 23-22 and bit 0 are not kept
        WREG    RASDESC0_P, 0x35
        WREG    RASDESC1_P, 0x12
        WREG    RASDESC2_P, 0xC8
        RCHK    RASDESC0_P, 0x34
        RCHK    RASDESC1_P, 0x12
        RCHK    RASDESC2_P, 0x08
        ld      d,0x33                  ; the window, all 16 bits of each
        ld      hl,w_test
        ld      bc,RASCLIPMIN_P
        ld      e,8
        call    outs
        ld      hl,w_test
        ld      bc,RASCLIPMIN_P
        ld      e,8
        call    ins
        ld      d,0x34
        WREG    RASCLIPMAX2_P, 0x45
        RCHK    RASCLIPMAX1_P, 0x01
        RCHK    RASCLIPMAX2_P, 0x45
        RCHK    RASCLIPMAX3_P, 0x7F
        ld      hl,w_full               ; the window for what follows: the whole bitmap
        call    window

        ; ---- R2: a line by RUN, the spec's example: (2,1) to (9,4)
        ld      d,0x40
        ld      hl,j_line
        call    runok
        ld      d,0x41
        ld      hl,x_line
        ld      de,BM
        ld      b,6*16
        call    cmpm
        ld      d,0x42                  ; DMXINT at the end, with or without IRQ
        RCHK    DMXINT_P, DMXINT_RAS_M
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R3: the pattern through minterm 0xCA, NOLAST, and the
        ; window's left edge at x = 2
        ld      d,0x50
        WREG    RASCLIPMIN2_P, 2
        ld      hl,j_pat
        call    runok
        WREG    RASCLIPMIN2_P, 0
        ld      d,0x51
        ld      hl,x_pat
        ld      de,BM + 6*16
        ld      b,16
        call    cmpm

        ; ---- R4: a triangle by START, the spec's example; the job
        ; registers hold the descriptor after
        ld      d,0x60
        WREG    DMXINT_P, DMXINT_RAS_M
        WREG    RASDESC0_P, low DSC_P
        WREG    RASDESC1_P, high DSC_P
        WREG    RASDESC2_P, DSC_P >> 16
        WREG    RASCMD_P, RASCMD_START_M
        call    waitok
        ld      d,0x61
        ld      hl,x_tri
        ld      de,BM2
        ld      b,10*16
        call    cmpm
        ld      d,0x62
        ld      hl,descs
        ld      bc,RASCTRL_P
        ld      e,32
        call    ins
        ld      d,0x63
        RCHK    RASDESC0_P, low DSC_P
        RCHK    RASDESC1_P, high DSC_P
        RCHK    RASDESC2_P, DSC_P >> 16
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R5: a chain. Its first job has no IRQ: DMXINT stays clear
        ; until the end
        ld      d,0x70
        WREG    RASDESC0_P, low (DSC_P + 0x20)
        WREG    RASDESC1_P, high (DSC_P + 0x20)
        WREG    RASCMD_P, RASCMD_START_M
        ld      hl,0                    ; the first job is done
.c1:    ld      a,(BM + 10*16)
        cp      0x11
        jr      z,.c1d
        dec     hl
        ld      a,h
        or      l
        jr      nz,.c1
        jp      fail
.c1d:   ld      d,0x71
        RCHK    DMXINT_P, 0
        RCHK    RASSTAT_P, RASSTAT_BUSY_M
        ld      d,0x72
        call    waitok
        RCHK    DMXINT_P, DMXINT_RAS_M
        ld      d,0x73
        MCHK    BM + 11*16 + 15, 0x22   ; the second job's last pixel inside the window
        MCHK    BM + 11*16, 0
        ld      d,0x74                  ; the last descriptor run
        RCHK    RASDESC0_P, low (DSC_P + 0x40)
        RCHK    RASDESC1_P, high (DSC_P + 0x40)
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R6: ... and with IRQ: DMXINT while the second job runs
        ld      d,0x80
        ld      a,(DSC + 0x21)
        or      high RIRQ
        ld      (DSC + 0x21),a
        WREG    RASDESC0_P, low (DSC_P + 0x20)
        WREG    RASCMD_P, RASCMD_START_M
        ld      hl,0
.c2:    ld      bc,DMXINT_P
        in      a,(c)
        and     DMXINT_RAS_M
        jr      nz,.c2d
        dec     hl
        ld      a,h
        or      l
        jr      nz,.c2
        jp      fail
.c2d:   ld      d,0x81
        RCHK    RASSTAT_P, RASSTAT_BUSY_M
        ld      d,0x82
        call    waitok
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R7: a reserved bit of RASCTRL (bit 13) is an error: ERR and
        ; DMXINT, nothing written. The bit is kept, but reads 0
        ld      d,0x90
        ld      hl,j_bad
        call    runjob
        call    waitr
        cp      RASSTAT_ERR_M
        jp      nz,fail
        ld      d,0x91
        RCHK    DMXINT_P, DMXINT_RAS_M
        RCHK    RASCTRL1_P, high R8BPP
        ld      d,0x92
        ld      hl,BM + 12*16
        ld      b,4
        call    cmpz
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R8: an error in a chain (bit 18): the chain ends, RASDESC
        ; names the descriptor; the next start clears ERR
        ld      d,0xA0
        WREG    RASDESC0_P, low (DSC_P + 0x60)
        WREG    RASCMD_P, RASCMD_START_M
        call    waitr
        cp      RASSTAT_ERR_M
        jp      nz,fail
        ld      d,0xA1
        MCHK    BM + 13*16, 0x33        ; the job before it ran
        ld      hl,BM + 12*16
        ld      b,4
        call    cmpz
        ld      d,0xA2
        RCHK    RASDESC0_P, low (DSC_P + 0x80)
        RCHK    RASDESC1_P, high (DSC_P + 0x80)
        ld      d,0xA3
        ld      hl,j_dot
        call    runok
        MCHK    BM + 13*16 + 15, 0x01
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R9: the job registers, RASDESC and the window are not
        ; written while busy; STOP ends the job and the chain
        ld      d,0xB0
        ld      hl,j_long
        call    runjob
        WREG    RASCTRL3_P, 0x12
        RCHK    RASCTRL3_P, 0xCC
        ld      d,0xB1
        WREG    RASDESC0_P, 0x56
        RCHK    RASDESC0_P, low (DSC_P + 0x80)
        ld      d,0xB2
        WREG    RASCLIPMAX0_P, 0x01
        RCHK    RASCLIPMAX0_P, 0x0F
        ld      d,0xB3
        RCHK    RASSTAT_P, RASSTAT_BUSY_M
        WREG    RASCMD_P, RASCMD_STOP_M
        ld      d,0xB4
        call    waitok
        RCHK    DMXINT_P, DMXINT_RAS_M
        ld      d,0xB5
        MCHK    BM + 14*16 + 15, 0x44   ; it had drawn its pixels in the window ...
        MCHK    BM + 15*16, 0           ; ... and the chain was not followed
        WREG    DMXINT_P, DMXINT_RAS_M

        ; ---- R10: with DMACON.BLTEN clear a job waits
        ld      d,0xC0
        WREG    DMACON_P, DMACON_BLTEN_M
        ld      hl,j_held
        call    runjob
        ld      b,100
        djnz    $
        RCHK    RASSTAT_P, RASSTAT_BUSY_M
        MCHK    BM + 15*16 + 3, 0
        ld      d,0xC1
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_BLTEN_M
        call    waitok
        MCHK    BM + 15*16 + 3, 0x88

        ; ---- R11: the interrupt request (source 4, shared with the
        ; blitter) is DMXINT and DMXINTEN, bit by bit
        ld      d,0xD0
        RBIT    INTRAW0_P, 1 << INTB_BLT, 1 << INTB_BLT
        ld      d,0xD1                  ; only the blitter's enable: no request
        WREG    DMXINTEN_P, DMXINTEN_BLT_M
        RBIT    INTRAW0_P, 1 << INTB_BLT, 0
        ld      d,0xD2
        WREG    DMXINTEN_P, DMXINTEN_RAS_M
        RBIT    INTRAW0_P, 1 << INTB_BLT, 1 << INTB_BLT
        ld      d,0xD3                  ; clearing the blitter's flag leaves this one
        WREG    DMXINT_P, DMXINT_BLT_M
        RCHK    DMXINT_P, DMXINT_RAS_M
        ld      d,0xD4
        WREG    DMXINT_P, DMXINT_RAS_M
        RCHK    DMXINT_P, 0
        RBIT    INTRAW0_P, 1 << INTB_BLT, 0
        WREG    DMXINTEN_P, DMXINTEN_BLT_M | DMXINTEN_RAS_M

        ; ---- R12: the blitter and the rasteriser run at the same time
        ld      hl,WARM                 ; the blitter's first job reads C (its C
        ld      bc,4                    ; register is not reset)
        call    zero
        ld      hl,WIDE
        ld      bc,0x100
        call    zero
        ld      a,0xFF
        ld      (WIDE + 0x100),a
        ld      (WIDE + 0x103),a
        xor     a
        ld      (BIG),a
        ld      (BIG + 0xFFF),a
        ld      d,0xE0
        ld      hl,j_warm
        ld      bc,BLTCTRL0_P
        ld      e,32
        call    outs
        WREG    BLTCMD_P, BLTCMD_RUN_M
        call    waitb
        RCHK    BLTSTAT_P, 0
        WREG    DMXINT_P, DMXINT_BLT_M
        ld      hl,w_wide               ; the window: 256 x 1
        call    window
        ld      hl,j_fill
        ld      bc,BLTCTRL0_P
        ld      e,32
        call    outs
        ld      hl,j_wide
        ld      bc,RASCTRL_P
        ld      e,32
        call    outs
        WREG    BLTCMD_P, BLTCMD_RUN_M
        WREG    RASCMD_P, RASCMD_RUN_M
        ld      d,0xE1                  ; both were busy
        RCHK    RASSTAT_P, RASSTAT_BUSY_M
        RCHK    BLTSTAT_P, BLTSTAT_BUSY_M
        ld      d,0xE2
        call    waitok
        call    waitb
        RCHK    BLTSTAT_P, 0
        ld      d,0xE3
        RCHK    DMXINT_P, DMXINT_BLT_M | DMXINT_RAS_M
        WREG    DMXINT_P, DMXINT_BLT_M | DMXINT_RAS_M
        ld      d,0xE4
        ld      hl,WIDE
        ld      b,0                     ; 256
.w1:    ld      a,(hl)
        cp      0x99
        jp      nz,fail
        inc     hl
        djnz    .w1
        MCHK    WIDE + 0x100, 0xFF
        ld      d,0xE5
        MCHK    BIG, 0x3C
        MCHK    BIG + 0xFFF, 0x3C
        ld      hl,w_full
        call    window

        ; ---- R13: the copper's WAIT with B waits for the rasteriser too
        ld      hl,clist
        ld      de,COPL
        ld      bc,clist_end - clist
        ldir
        ld      d,0xF0
        WREG    BGCOLOR0_P, 0
        WREG    BGCOLOR1_P, 0
        WREG    BGCOLOR2_P, 0
        ld      hl,j_long2
        call    runjob
        WREG    COP1LC0_P, low COPL_P
        WREG    COP1LC1_P, high COPL_P
        WREG    COP1LC2_P, COPL_P >> 16
        WREG    COPCON_P, COPCON_EN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_COPEN_M
        WREG    COPJMP1_P, 0
        ld      b,50
        djnz    $
        ld      bc,BGCOLOR0_P           ; not written yet ...
        in      e,(c)
        RCHK    RASSTAT_P, RASSTAT_BUSY_M   ; ... and the job was still running then
        ld      a,e
        or      a
        jp      nz,fail
        ld      d,0xF1
        call    waitok
        ld      b,50
        djnz    $
        RCHK    BGCOLOR0_P, 0x56
        RCHK    BGCOLOR1_P, 0x34
        RCHK    BGCOLOR2_P, 0x12
        WREG    DMACON_P, DMACON_COPEN_M
        WREG    COPCON_P, 0
        WREG    BGCOLOR0_P, 0
        WREG    BGCOLOR1_P, 0
        WREG    BGCOLOR2_P, 0
        WREG    DMXINT_P, DMXINT_RAS_M

        ld      hl,pass
        call    puts
        jp      stop

; ---------------------------------------------------------------- helpers
; Write E bytes from HL to the register ports from BC up (B the offset).
; HL is left after them
outs:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        dec     e
        jr      nz,outs
        ret

; Compare E bytes read from the ports from BC up with HL; fail D
ins:    in      a,(c)
        cp      (hl)
        jp      nz,fail
        inc     hl
        inc     b
        dec     e
        jr      nz,ins
        ret

; Compare B bytes at DE with HL; fail D
cmpm:   ld      a,(de)
        cp      (hl)
        jp      nz,fail
        inc     hl
        inc     de
        djnz    cmpm
        ret

; Check B bytes at HL are 0; fail D
cmpz:   ld      a,(hl)
        or      a
        jp      nz,fail
        inc     hl
        djnz    cmpz
        ret

; Clear BC bytes (2 or more) at HL. D and E changed
zero:   ld      (hl),0
        ld      d,h
        ld      e,l
        inc     de
        dec     bc
        ldir
        ret

; The clip window from the 8 bytes at HL
window: ld      bc,RASCLIPMIN_P
        ld      e,8
        jr      outs

; Write the 32-byte job at HL into the job registers and RUN it
runjob: ld      bc,RASCTRL_P
        ld      e,32
        call    outs
        WREG    RASCMD_P, RASCMD_RUN_M
        ret

; The same, wait for the end, and fail D on an error
runok:  call    runjob
; Wait for the end, and fail D on an error
waitok: call    waitr
        or      a
        jp      nz,fail
        ret

; Wait while RASSTAT.BUSY; A = RASSTAT
waitr:  ld      bc,RASSTAT_P
.w:     in      a,(c)
        bit     RASSTAT_BUSY_B,a
        jr      nz,.w
        ret

; Wait while BLTSTAT.BUSY
waitb:  ld      bc,BLTSTAT_P
.w:     in      a,(c)
        rra
        jr      c,.w
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

; ---------------------------------------------------------------- data
; Windows: YMIN, XMIN, YMAX, XMAX, low byte first
w_test: dw      0x8001, 0xFFF0, 0x0123, 0x7FFF
w_full: dw      0, 0, 15, 15            ; the 16 x 16 bitmaps
w_wide: dw      0, 0, 0, 255            ; 256 x 1

;               CTRL  P0  P1  P2  DPT  STRIDE  PAT  NEXT
j_regs: dd      0xA5C3B5E7, 0x12345678, 0x9ABCDEF0, 0x0FEDCBA9, 0x07654321, 0xABCD8001, 0x5555F0F0, 0x00222222
x_regs: dd      0xA50311E7, 0x12345678, 0x9ABCDEF0, 0x0FEDCBA9, 0x00654321, 0x00008001, 0x0000F0F0, 0x00222222

j_line: RJOB    LINE8 | 0x55,  2, 1,  9, 4,  0, 0,  BM_P, 16, 0xFFFF, 0
j_pat:  RJOB    0xCA*MT | R8BPP | RNOLAST | 0x77,  0, 6,  15, 6,  0, 0,  BM_P, 16, 0xF0FF, 0
j_bad:  RJOB    LINE8 | BCONST | 0xEE,  0, 12,  3, 12,  0, 0,  BM_P, 16, 0xFFFF, 0  ; bit 13 is reserved here
j_dot:  RJOB    LINE8 | 0x01,  15, 13,  15, 13,  0, 0,  BM_P, 16, 0xFFFF, 0
j_long: RJOB    LINE8 | 0x44,  1, 14,  FAR, 14,  0, 0,  BM_P, 16, 0xFFFF, DSC_P + 0xA0
j_held: RJOB    LINE8 | 0x88,  3, 15,  3, 15,  0, 0,  BM_P, 16, 0xFFFF, 0
j_wide: RJOB    LINE8 | 0x99,  0, 0,  FAR, 0,  0, 0,  WIDE_P, 256, 0xFFFF, 0
j_long2: RJOB   LINE8 | 0x45,  1, 14,  FAR, 14,  0, 0,  BM_P, 16, 0xFFFF, 0
; the blitter's: D = B xor C over 4 bytes (it reads C), and a 4 KB fill
j_warm: BJOB    B8 | BCONST | 0x66*MT, 0, WARM_P, 4, 1, 0, 0, 0, 0, 0, 0
j_fill: BJOB    B8 | BCONST | 0xCC*MT, 0, BIG_P, 0x1000, 1, 0, 0, 0, 0x3C3C, 0, 0

; the descriptors, copied to DSC
descs:  RJOB    TRI8 | 0x33,  10, 2,  3, 6,  14, 9,  BM2_P, 16, 0, 0                ; +00 R4: the spec's triangle
        RJOB    LINE8 | 0x11,  0, 10,  0, 10,  0, 0,  BM_P, 16, 0xFFFF, DSC_P + 0x40 ; +20 R5: a chain: a pixel ...
        RJOB    LINE8 | 0x22,  1, 11,  FAR, 11,  0, 0,  BM_P, 16, 0xFFFF, 0         ; +40 ... then a long line
        RJOB    LINE8 | 0x33,  0, 13,  0, 13,  0, 0,  BM_P, 16, 0xFFFF, DSC_P + 0x80 ; +60 R8: a job ...
        RJOB    LINE8 | 0x40000 | 0xEE,  0, 12,  3, 12,  0, 0,  BM_P, 16, 0xFFFF, 0 ; +80 ... then an error
        RJOB    LINE8 | 0x66,  0, 15,  0, 15,  0, 0,  BM_P, 16, 0xFFFF, 0           ; +A0 R9: after the stopped job

; what the bitmaps hold, 16 bytes a row
x_line: ds      16, 0                   ; (2,1) (3,1) (4,2) (5,2) (6,3) (7,3) (8,4) (9,4)
        ds      2, 0
        ds      2, 0x55
        ds      12, 0
        ds      4, 0
        ds      2, 0x55
        ds      10, 0
        ds      6, 0
        ds      2, 0x55
        ds      8, 0
        ds      8, 0
        ds      2, 0x55
        ds      6, 0
        ds      16, 0
x_pat:  db      0, 0, 0x77, 0x77, 0, 0, 0, 0    ; x 2-3 (0-1 are outside), 8-14 (15 is the last)
        db      0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0
x_tri:  ds      3*16, 0                 ; rows 0-2: none
        ds      9, 0                    ; row 3: 9 to 10
        ds      2, 0x33
        ds      5, 0
        ds      7, 0                    ; row 4: 7 to 11
        ds      5, 0x33
        ds      4, 0
        ds      5, 0                    ; row 5: 5 to 11
        ds      7, 0x33
        ds      4, 0
        ds      3, 0                    ; row 6: 3 to 12
        ds      10, 0x33
        ds      3, 0
        ds      7, 0                    ; row 7: 7 to 12
        ds      6, 0x33
        ds      3, 0
        ds      11, 0                   ; row 8: 11 to 13
        ds      3, 0x33
        ds      2, 0
        ds      16, 0                   ; row 9: not drawn

; R13's copper list: when the blitter and the rasteriser are idle, set BGCOLOR
clist:  CWAITB  0, 0
        CMOVEA  BGCOLOR, 0x123456
        CSTOP
clist_end:
