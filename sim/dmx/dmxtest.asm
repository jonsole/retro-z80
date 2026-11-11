; Blitter directed test (ticket #103; spec 14). Runs in place of the boot
; ROM (tb.v +rom=dmxtest.hex) and prints "PASS" or "FAIL nn".
;
; Each table entry is a 16-byte source (copied to physical 0x008000), a
; 16-byte destination before the job (physical 0x009000), a 32-byte job
; written to the job registers and started with RUN, and the 16 bytes the
; destination must hold after it. Then: a chain of two descriptors started
; with BLTDESC and START, with IRQ; MASK 3; STOP; register checks; a job
; written through the register page with LDIR and LDDR.
;
; Z80 0xC000 (window 6) is physical 0x008000, 0xD000 is 0x009000, and 0xE000
; (window 7) is 0x00A000, as after reset.

        DEVICE  NOSLOT64K
        include "hw.inc"

SRC     equ     0xC000                  ; physical 0x008000
DST     equ     0xD000                  ; physical 0x009000
DESCS   equ     0xE000                  ; physical 0x00A000
SRC_P   equ     0x008000
DST_P   equ     0x009000
DESCS_P equ     0x00A000

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
    ; A job, as the job registers and a descriptor: BLTCTRL, BLTBPT, BLTDPT,
    ; BLTSIZE, BLTAPT, BLTSTRIDE, BLTVALUE, BLTNEXT, each low byte first.
    ; The pointers take their pixel (BIT) in bits 26-24.
    MACRO JOB ctl, bpt, dpt, wid, hgt, apt, dstr, bstr, val, astr, nxt
        dd      ctl, bpt, dpt
        dw      wid, hgt
        dd      apt
        dw      dstr, bstr, val, astr
        dd      nxt
    ENDM

B8      equ     0x0300                  ; BPP 3: 8 bpp
B4      equ     0x0200                  ; BPP 2: 4 bpp
RTL     equ     0x0400
IRQ     equ     0x1000
BCONST  equ     0x2000
MIMG    equ     0x20000                 ; MASK 1: a 1 bpp image at BLTAPT
MKEY    equ     0x40000                 ; MASK 2: B compared with KEY
MBAD    equ     0x60000                 ; MASK 3: an error
MT      equ     0x1000000               ; MINTERM x: x * MT
PIX     equ     0x1000000               ; a pointer's BIT x: x * PIX

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M

        ; ---- checks 1-n: the table of single jobs
        ld      a,1
        ld      (tnum),a
        ld      hl,tests
.next:  ld      a,(hl)
        cp      0xFF
        jr      z,chain
        ld      de,SRC                  ; the source
        ld      bc,16
        ldir
        ld      de,DST                  ; the destination before
        ld      bc,16
        ldir
        ld      a,(tnum)
        ld      d,a
        call    runjob                  ; HL: the job; on to the expected bytes
        call    waitb
        RCHK    BLTSTAT_P, 0
        ld      de,DST
        ld      b,16
.cmp:   ld      a,(de)
        cp      (hl)
        jr      nz,.bad
        inc     de
        inc     hl
        djnz    .cmp
        ld      a,(tnum)
        inc     a
        ld      (tnum),a
        jr      .next
.bad:   ld      a,(tnum)
        ld      d,a
        jp      fail

        ; ---- a chain of two fills from descriptors, the second with IRQ
chain:  ld      hl,DST
        ld      de,DST+1
        ld      (hl),0xEE
        ld      bc,15
        ldir
        ld      hl,descs
        ld      de,DESCS
        ld      bc,64
        ldir
        ld      d,0x20
        WREG    DMXINT_P, DMXINT_BLT_M  ; clear what the table's jobs left
        RCHK    DMXINT_P, 0
        WREG    BLTDESC0_P, low DESCS_P
        WREG    BLTDESC1_P, high DESCS_P
        WREG    BLTDESC2_P, DESCS_P >> 16
        WREG    BLTCMD_P, BLTCMD_START_M
        call    waitb
        RCHK    BLTSTAT_P, 0
        ld      d,0x21
        RCHK    DMXINT_P, DMXINT_BLT_M
        ld      d,0x22
        RCHK    BLTDESC0_P, low (DESCS_P + 32)  ; the last descriptor loaded
        RCHK    BLTDESC1_P, high (DESCS_P + 32)
        ld      d,0x23                  ; the second descriptor's job is in the registers
        RCHK    BLTVALUE0_P, 0x66
        RCHK    BLTDPT0_P, low (DST_P + 5)
        ld      d,0x24
        ld      a,(DST+1)
        cp      0x55
        jp      nz,fail
        ld      a,(DST+2)
        cp      0xEE
        jp      nz,fail
        ld      a,(DST+5)
        cp      0x66
        jp      nz,fail
        ld      d,0x25
        WREG    DMXINT_P, DMXINT_BLT_M  ; W1C
        RCHK    DMXINT_P, 0

        ; ---- MASK 3: an error; nothing written; ERR until the next start
        ld      d,0x30
        ld      a,0xEE
        ld      (DST),a
        ld      hl,job_mask3
        call    runjob
        call    waitb
        RCHK    BLTSTAT_P, BLTSTAT_ERR_M
        RCHK    DMXINT_P, DMXINT_BLT_M
        ld      a,(DST)
        cp      0xEE
        jp      nz,fail
        ld      d,0x31
        WREG    DMXINT_P, DMXINT_BLT_M
        ld      hl,job_one
        call    runjob
        call    waitb
        RCHK    BLTSTAT_P, 0
        ld      a,(DST)
        cp      0x77
        jp      nz,fail

        ; ---- writes ignored while BUSY, then STOP: a 4000-byte fill
LAST    equ     DST + 0x100 + 3999      ; the job's last byte
        ld      d,0x38
        ld      a,0xEE
        ld      (LAST),a
        ld      hl,job_long
        call    runjob
        WREG    BLTCTRL3_P, 0x33
        RCHK    BLTSTAT_P, BLTSTAT_BUSY_M
        RCHK    BLTCTRL3_P, 0xCC
        ld      d,0x39
        WREG    BLTCMD_P, BLTCMD_STOP_M
        call    waitb
        RCHK    BLTSTAT_P, 0
        ld      a,(LAST)
        cp      0xEE
        jp      nz,fail
        ld      a,(DST + 0x100)         ; it had begun
        cp      0x99
        jp      nz,fail
        ld      d,0x3A                  ; and the same job runs to the end
        WREG    BLTCMD_P, BLTCMD_RUN_M
        call    waitb
        ld      a,(LAST)
        cp      0x99
        jp      nz,fail

        ; ---- registers
        ld      d,0x40                  ; the job registers read back
        WREG    BLTCTRL3_P, 0x5A
        RCHK    BLTCTRL3_P, 0x5A
        ld      d,0x41                  ; reserved bits are not stored
        WREG    BLTCTRL1_P, 0xFF
        RCHK    BLTCTRL1_P, 0x37
        WREG    BLTCTRL2_P, 0xFF
        RCHK    BLTCTRL2_P, 0x06
        WREG    BLTBPT3_P, 0xFF
        RCHK    BLTBPT3_P, 0x07
        WREG    BLTNEXT3_P, 0xFF
        RCHK    BLTNEXT3_P, 0x00
        ld      d,0x42                  ; reserved offsets read 0xFF, BLTCMD 0x00
        RCHK    BLTCMD_P + 0x0100, 0xFF
        RCHK    BLTSTAT_P + 0x0100, 0xFF
        RCHK    BLTCMD_P, 0x00

        ; ---- a job written as a 32-byte image through the register page
        ; (page 0x3F8 in window 7: the job registers at 0xE000 + 0x1140),
        ; with LDIR and with LDDR
        ld      d,0x43
        WREG    MMU7_0_P, 0xF8
        WREG    MMU7_1_P, 0x03
        ld      hl,job_ldir
        ld      de,0xE000 + 0x1000 + BLTCTRL
        ld      bc,32
        ldir
        call    rungo
        ld      hl,DST + 0x10
        ld      a,0x5A
        call    chk4
        ld      d,0x44
        ld      hl,job_lddr + 31
        ld      de,0xE000 + 0x1000 + BLTCTRL + 31
        ld      bc,32
        lddr
        call    rungo
        ld      hl,DST + 0x14
        ld      a,0xA5
        call    chk4
        WREG    MMU7_0_P, 5             ; window 7 back to page 5
        WREG    MMU7_1_P, 0

        ld      hl,pass
        call    puts
        jp      stop

; RUN the job in the registers, wait, check BLTSTAT is clear (D: the check)
rungo:  WREG    BLTCMD_P, BLTCMD_RUN_M
        call    waitb
        RCHK    BLTSTAT_P, 0
        ret

; Check the 4 bytes at HL are A
chk4:   ld      b,4
.lp:    cp      (hl)
        jp      nz,fail
        inc     hl
        djnz    .lp
        ret

; Write the 32-byte job at HL into the job registers and RUN it. HL is left
; after the job.
runjob: ld      bc,BLTCTRL0_P
.lp:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high BLTCTRL0_P + 0x20
        jr      nz,.lp
        ld      bc,BLTCMD_P
        ld      a,BLTCMD_RUN_M
        out     (c),a
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

tnum    equ     0xBF00                  ; the check number (window 5, SRAM)

tests:
        ; 1: XOR (0x66), which reads C
        db      0x0F, 0xF0, 0xAA, 0x55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     B8|0x66*MT, SRC_P, DST_P+3, 4, 1, 0, 0, 0, 0, 0, 0
        db      0xEE, 0xEE, 0xEE, 0xE1, 0x1E, 0x44, 0xBB, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 2: fill 7 bytes from an odd address: VALUE by address, in pixel order
        ; (its high byte, BLTVALUE1, at even addresses)
        ds      16, 0
        ds      16, 0xEE
        JOB     B8|BCONST|0xCC*MT, 0, DST_P+1, 7, 1, 0, 0, 0, 0x2211, 0, 0
        db      0xEE, 0x11, 0x22, 0x11, 0x22, 0x11, 0x22, 0x11, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 3: a 2D copy, 3 x 2, from odd to even addresses, strides 4 (B) and 5 (D)
        db      0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
        ds      16, 0xEE
        JOB     B8|0xCC*MT, SRC_P+1, DST_P+2, 3, 2, 0, 5, 4, 0, 0, 0
        db      0xEE, 0xEE, 0x11, 0x12, 0x13, 0xEE, 0xEE, 0x15, 0x16, 0x17, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 4: cookie-cut with the key compare, key colour 0
        db      0x00, 0x21, 0x00, 0x23, 0x24, 0x00, 0x26, 0x27, 0, 0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     B8|MKEY|0xCA*MT, SRC_P, DST_P+1, 6, 1, 0, 0, 0, 0, 0, 0
        db      0xEE, 0xEE, 0x21, 0xEE, 0x23, 0x24, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 5: 4 bpp, 3 pixels from source pixel 1 to destination pixel 1
        db      0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     B4|0xCC*MT, SRC_P+1*PIX, DST_P+1+1*PIX, 3, 1, 0, 0, 0, 0, 0, 0
        db      0xEE, 0xE2, 0x34, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 6: cookie-cut through a 1 bpp mask image from bit 2: 1001 0111
        db      0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0xA5, 0xF0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     B8|MIMG|0xCA*MT, SRC_P, DST_P, 8, 1, SRC_P+8+2*PIX, 0, 0, 0, 0, 0
        db      0x31, 0xEE, 0xEE, 0x34, 0xEE, 0x36, 0x37, 0x38, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 7: an overlapping copy two bytes up, right to left: the pointers name the last pixels
        ds      16, 0
        db      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
        JOB     B8|RTL|0xCC*MT, DST_P+5, DST_P+7, 6, 1, 0, 0, 0, 0, 0, 0
        db      0x00, 0x01, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
        ; 8: an overlapping copy one row down, bottom up with negative strides
        db      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db      0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x60, 0x61, 0x62, 0x63, 0xEE, 0xEE, 0xEE, 0xEE
        JOB     B8|0xCC*MT, DST_P+8, DST_P+12, 4, 3, 0, 0xFFFC, 0xFFFC, 0, 0, 0
        db      0x40, 0x41, 0x42, 0x43, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x60, 0x61, 0x62, 0x63
        db      0xFF

descs:  JOB     B8|BCONST|0xCC*MT, 0, DST_P+1, 1, 1, 0, 0, 0, 0x5555, 0, DESCS_P+32
        JOB     B8|BCONST|IRQ|0xCC*MT, 0, DST_P+5, 1, 1, 0, 0, 0, 0x6666, 0, 0

job_mask3:  JOB B8|BCONST|MBAD|0xCC*MT, 0, DST_P, 1, 1, 0, 0, 0, 0x7777, 0, 0
job_one:    JOB B8|BCONST|0xCC*MT, 0, DST_P, 1, 1, 0, 0, 0, 0x7777, 0, 0
job_ldir:   JOB B8|BCONST|0xCC*MT, 0, DST_P+0x10, 4, 1, 0, 0, 0, 0x5A5A, 0, 0
job_lddr:   JOB B8|BCONST|0xCC*MT, 0, DST_P+0x14, 4, 1, 0, 0, 0, 0xA5A5, 0, 0
job_long:   JOB B8|BCONST|0xCC*MT, 0, DST_P+0x100, 4000, 1, 0, 0, 0, 0x9999, 0, 0
