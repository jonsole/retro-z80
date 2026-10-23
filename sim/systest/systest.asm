; System test ROM (tickets #4 and #5): the system registers, the I/O
; decode, SRAM byte writes, the writable boot ROM, the boot ROM's memory and
; MMU self-test (firmware/boot/selftest.asm, checks 0x41 up) and a soft
; reset. Runs in place of the
; boot ROM (tb.v +rom=systest.hex) and prints "PASS" or "FAIL" with the
; number of the first check that failed.
;
; The first run (RESETWHY = POWER) checks everything, leaves a mark in SRAM
; and writes SYSRESET. The second run (RESETWHY = SOFTWARE) checks that the
; mark survived, ROMLOCK stayed set and the MMU is back at its reset
; mapping, then prints the result.

        DEVICE  NOSLOT64K
        include "hw.inc"

MARK    equ     0x8000                  ; SRAM page 2 (window 4): survives a soft reset
SCRATCH equ     0x8010
ROMTEST equ     0x3FF0                  ; boot ROM page 1, unused by this program

        ORG     0x0000

reset:  di
        jp      start

        ds      0x38 - $, 0xFF
        jp      st_rst38                ; RST 38h: the self-test's register page fetch

start:  ld      sp,0x0000
        ld      bc,SERCON_P
        ld      a,SERCON_EN_M | SERCON_CTLEN_M
        out     (c),a
        ld      bc,RESETWHY_P
        in      a,(c)
        cp      RESETWHY_SOFTWARE_M
        jp      z,second
        ld      d,1                     ; check 1: RESETWHY = POWER at power-on
        cp      RESETWHY_POWER_M
        jp      nz,fail

        ; ---- identification
        ld      d,2                     ; check 2: SYSID through its port, IN r,(C)
        ld      bc,SYSID_P
        in      e,(c)
        ld      a,e
        cp      0x5A
        jp      nz,fail
        ld      d,3                     ; check 3: SYSID through IN A,(n), A = register
        ld      a,SYSID
        in      a,(SYSPAGE)
        cp      0x5A
        jp      nz,fail
        ld      d,4                     ; check 4: SYSVER (build version 0.1)
        ld      bc,SYSVER_P
        in      a,(c)
        cp      0x01
        jp      nz,fail
        ld      d,5                     ; check 5: SYSCFG: CPU 0 (Z80), CHIPMB 4
        inc     b                       ; SYSCFG is the next register
        in      a,(c)
        cp      4 << SYSCFG_CHIPMB_B
        jp      nz,fail

        ; ---- I/O decode
        ld      d,6                     ; check 6: a reserved page reads 0xFF
        ld      bc,0x7001               ; register 0x70 of page 0x01
        in      a,(c)
        cp      0xFF
        jp      nz,fail
        ld      d,7                     ; check 7: a custom page with no unit yet reads 0xFF
        ld      bc,0x0010
        in      a,(c)
        cp      0xFF
        jp      nz,fail
        ld      d,8                     ; check 8: OUT (n),A puts A on A15-A8: no write to SYSCON
        ld      a,SYSCON_ROMWE_M        ; port 0x0274 is reserved page 0x74
        out     (SYSCON),a
        ld      bc,SYSCON_P
        in      a,(c)
        or      a
        jp      nz,fail
        ld      d,9                     ; check 9: TXSPACE reads 255 through page and register
        ld      bc,SERSTAT0_P
        in      a,(c)
        cp      255
        jp      nz,fail

        ; ---- SRAM byte writes
        ld      d,10                    ; check 10: even and odd bytes kept apart
        ld      hl,SCRATCH
        ld      (hl),0x11
        inc     hl
        ld      (hl),0x22
        dec     hl
        ld      a,(hl)
        cp      0x11
        jp      nz,fail
        inc     hl
        ld      a,(hl)
        cp      0x22
        jp      nz,fail
        ld      d,11                    ; check 11: a 16-bit store and load
        ld      hl,0xA55A
        ld      (SCRATCH+2),hl
        ld      hl,0
        ld      hl,(SCRATCH+2)
        ld      a,h
        cp      0xA5
        jp      nz,fail
        ld      a,l
        cp      0x5A
        jp      nz,fail

        ; ---- writable boot ROM (spec 7, section 4.3)
        ld      d,12                    ; check 12: ROM writes ignored while ROMWE is 0
        ld      a,(ROMTEST)
        ld      e,a
        cpl
        ld      (ROMTEST),a
        ld      a,(ROMTEST)
        cp      e
        jp      nz,fail
        ld      d,13                    ; check 13: SYSCON.ROMWE reads back; bits 0, 7-3 read 0
        ld      bc,SYSCON_P
        ld      a,0xFB                  ; everything but ROMLOCK
        out     (c),a
        in      a,(c)
        cp      SYSCON_ROMWE_M
        jp      nz,fail
        ld      d,14                    ; check 14: with ROMWE, a ROM byte can be written
        ld      a,0x3C
        ld      (ROMTEST),a
        ld      a,0xC3
        ld      (ROMTEST+1),a
        ld      a,(ROMTEST)
        cp      0x3C
        jp      nz,fail
        ld      a,(ROMTEST+1)
        cp      0xC3
        jp      nz,fail
        ld      d,15                    ; check 15: ROMLOCK turns ROMWE off and keeps it off
        ld      a,SYSCON_ROMLOCK_M
        out     (c),a
        ld      a,SYSCON_ROMWE_M
        out     (c),a
        in      a,(c)
        cp      SYSCON_ROMLOCK_M
        jp      nz,fail
        ld      a,0x99
        ld      (ROMTEST),a
        ld      a,(ROMTEST)
        cp      0x3C
        jp      nz,fail

        ; ---- MMU (spec 2, section 9)
        ld      d,21                    ; check 21 (0x15): IN A,(n) with A = MMU0_0 reads it
        ld      a,MMU0_0
        in      a,(SYSPAGE)
        cp      0xFC
        jp      nz,fail
        call    selftest                ; checks 0x41 up
        ld      d,a
        jp      nz,fail

        ; ---- soft reset
        ld      hl,0x5AA5
        ld      (MARK),hl
        ld      hl,0x0040
        ld      bc,MMU3_0_P
        out     (c),l
        inc     b
        out     (c),h                   ; window 3: page 0x040
        ld      hl,PG_NONE
        ld      b,MMU4W_0
        out     (c),l
        inc     b
        out     (c),h                   ; window 4: writes to NONE
        ld      bc,SYSRESET_P
        ld      a,0x12                  ; a wrong value does nothing
        out     (c),a
        ld      d,16                    ; check 16: still running after a wrong SYSRESET value
        ld      a,SYSRESET_MAGIC
        out     (c),a
        ld      d,17                    ; check 17: SYSRESET did not reset
        jp      fail

second: ld      d,18                    ; check 18: SRAM kept across the soft reset
        ld      hl,(MARK)
        ld      a,h
        cp      0x5A
        jp      nz,fail
        ld      a,l
        cp      0xA5
        jp      nz,fail
        ld      d,19                    ; check 19: ROMLOCK kept, ROMWE cleared by the reset
        ld      bc,SYSCON_P
        in      a,(c)
        cp      SYSCON_ROMLOCK_M
        jp      nz,fail
        ld      d,20                    ; check 20: the ROM write made before the reset is kept
        ld      a,(ROMTEST)
        cp      0x3C
        jp      nz,fail
        ld      d,22                    ; check 22 (0x16): the reset put the MMU back
        ld      bc,MMU3_0_P
        in      a,(c)
        cp      1
        jp      nz,fail
        ld      b,MMU4W_0
        in      a,(c)
        cp      2
        jp      nz,fail
        inc     b
        in      a,(c)
        or      a
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
stop:   halt
        jr      stop

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
        jr      c,.out
        add     a,'A'-'9'-1
.out:   jr      putc

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

        include "selftest.asm"

pass:   db      "PASS", 13, 10, 0
failmsg: db     "FAIL ", 0
