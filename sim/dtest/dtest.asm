; Blitter random test (spec 14; retro-hw's blitter core). dgen.py puts
; random data, descriptors and a control table in the SRAM; this program
; runs the chains one after another, checks that none stopped with an
; error and that each set DMXINT.BLT at its end, and prints PASS or
; FAIL nn (nn: 1c the chain c'th from the end stopped with an error, 2c it
; did not set DMXINT). The testbench then dumps the SRAM (+ramout) and
; dmodel.py checks every byte. retro68k's sim/dtest/dtest.s (blitter2,
; 63df9a7), the random part; the directed tests are in sim/dmx.
;
; The control table (keep in step with dgen.py), physical 0x00A000, Z80
; 0xE000 in the map after reset:
CTL     equ     0xE000                  ; +0: the number of chains; then 36 bytes a chain:
C_LEN   equ     36                      ; the first descriptor (3 bytes and a spare; START),
                                        ; or 0 and the first job's 32 bytes (RUN)

        DEVICE  NOSLOT64K
        include "hw.inc"

    MACRO WREG xp, xv                   ; write xv to register port xp (A, B, C changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M
        WREG    DMXINTEN_P, DMXINTEN_BLT_M

        ld      a,(CTL)                 ; E: chains still to run
        ld      e,a
        ld      hl,CTL + 4
.chain: push    hl
        ld      a,(hl)                  ; a descriptor address, or 0
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        jr      z,.run
        pop     hl                      ; a chain in the SRAM: BLTDESC, START
        push    hl
        ld      bc,BLTDESC_P
        ld      d,3
.desc:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        dec     d
        jr      nz,.desc
        WREG    BLTCMD_P, BLTCMD_START_M
        jr      .wait
.run:   inc     hl                      ; the first job into the job registers, RUN
        inc     hl
        ld      bc,BLTCTRL_P
.job:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high BLTCTRL_P + 0x20
        jr      nz,.job
        WREG    BLTCMD_P, BLTCMD_RUN_M

.wait:  ld      bc,BLTSTAT_P            ; the chain's end
.busy:  in      a,(c)
        bit     BLTSTAT_BUSY_B,a
        jr      nz,.busy
        ld      d,a
        ld      a,e
        or      0x10
        bit     BLTSTAT_ERR_B,d
        ld      d,a
        jp      nz,fail                 ; FAIL 1c: an error
        add     a,0x10
        ld      d,a
        ld      bc,DMXINT_P
        in      a,(c)
        and     DMXINT_BLT_M
        jp      z,fail                  ; FAIL 2c: no DMXINT
        WREG    DMXINT_P, DMXINT_BLT_M  ; cleared (write 1)
        pop     hl
        ld      bc,C_LEN
        add     hl,bc
        dec     e
        jr      nz,.chain

        ld      hl,pass
        call    puts
        jp      stop

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
