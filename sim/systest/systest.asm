; System test ROM (tickets #4, #5 and #11): the system registers, the I/O
; decode, SRAM byte writes, the writable boot ROM, the video unit's first
; registers (VIDCON, BGCOLOR, VIDSIZE), the boot ROM's memory and
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
        ld      d,7                     ; check 7: a reserved custom register reads 0xFF
        ld      bc,0x0F10                       ; custom offset 0x00F
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

        ; ---- video (spec 4): VIDCON, BGCOLOR, VIDSIZE
        ld      d,23                    ; check 23 (0x17): VIDCON keeps bits 0, 2, 4, 5 only
        ld      bc,VIDCON_P
        ld      a,0xFF
        out     (c),a
        in      a,(c)
        cp      VIDCON_EN_M | VIDCON_BLANKALL_M | VIDCON_DIRECT_M | VIDCON_SHAREPAL_M
        jp      nz,fail
        ld      a,VIDCON_EN_M
        out     (c),a
        ld      d,24                    ; check 24 (0x18): BGCOLOR changes when its red byte is written
        ld      bc,BGCOLOR0_P
        ld      a,0x11
        out     (c),a                   ; blue and green wait in the CPU's colour assembly buffer
        inc     b
        ld      a,0x22
        out     (c),a
        in      a,(c)
        or      a                       ; green still 0
        jp      nz,fail
        dec     b
        in      a,(c)
        or      a                       ; blue still 0
        jp      nz,fail
        ld      b,BGCOLOR2
        ld      a,0x33
        out     (c),a                   ; red: all three
        in      a,(c)
        cp      0x33
        jp      nz,fail
        dec     b
        in      a,(c)
        cp      0x22
        jp      nz,fail
        dec     b
        in      a,(c)
        cp      0x11
        jp      nz,fail
        ld      d,25                    ; check 25 (0x19): VIDSIZE reads 720 x 576
        ld      hl,vidsize
        ld      bc,VIDSIZE0_P
.vsz:   in      a,(c)
        cp      (hl)
        jp      nz,fail
        inc     hl
        inc     b
        ld      a,b
        cp      VIDSIZE3 + 1
        jr      nz,.vsz
        call    vidregs                 ; checks 0x1B-0x22: palettes, L0, PRIO, DMACON

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
        ld      d,26                    ; check 26 (0x1A): the reset stopped the beam and cleared BGCOLOR
        ld      bc,VIDCON_P
        in      a,(c)
        or      a
        jp      nz,fail
        ld      bc,BGCOLOR2_P
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

; ---- video registers (spec 4, ticket #13): the palettes through PALIDX and
; PALDAT and through the register page, L0's registers, PRIO and DMACON.
; The layer stays off (DMACON.BPLEN is 0 throughout).
vidregs:
        ld      hl,PG_REGS
        ld      b,MMU3_0
        call    st_map                  ; window 3: the register page
        ld      d,0x1B                  ; check 1B: the default palette, read through PALDAT
        ld      bc,PALIDX0_P            ; PALIDX = 1 (PALETTE0, entry 1: Spectrum blue)
        ld      a,1
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      b,PALDAT
        in      a,(c)                   ; blue
        cp      0xD7
        jp      nz,fail
        in      a,(c)                   ; green
        or      a
        jp      nz,fail
        in      a,(c)                   ; red: steps PALIDX
        or      a
        jp      nz,fail
        ld      b,PALIDX0
        in      a,(c)
        cp      2
        jp      nz,fail
        ld      hl,W3+REGS_PALETTE0+15*3        ; entry 15, bright white, through the register page
        ld      a,(hl)
        inc     hl
        and     (hl)
        inc     hl
        and     (hl)
        inc     a
        jp      nz,fail
        ld      a,(W3+REGS_PALETTE0+16*3)       ; entry 16: black
        or      a
        jp      nz,fail
        ld      d,0x1C                  ; check 1C: PALDAT: blue and green wait, red writes the entry and steps into the next palette
        ld      bc,PALIDX0_P            ; PALIDX = 0x0FF
        ld      a,0xFF
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      b,PALDAT
        ld      a,0x11
        out     (c),a
        ld      a,0x22
        out     (c),a
        ld      a,(W3+REGS_PALETTE0+255*3)      ; still black
        or      a
        jp      nz,fail
        ld      a,0x33
        out     (c),a                   ; red
        ld      hl,W3+REGS_PALETTE0+255*3
        ld      a,(hl)
        cp      0x11
        jp      nz,fail
        inc     hl
        ld      a,(hl)
        cp      0x22
        jp      nz,fail
        inc     hl
        ld      a,(hl)
        cp      0x33
        jp      nz,fail
        ld      b,PALIDX1               ; PALIDX is now 0x100: PALETTE1, entry 0
        in      a,(c)
        cp      1
        jp      nz,fail
        dec     b
        in      a,(c)
        or      a
        jp      nz,fail
        ld      d,0x1D                  ; check 1D: the register page: red writes the entry; read back through PALDAT
        ld      hl,W3+REGS_SPRPALETTE+7*3       ; SPRPALETTE entry 7: Spectrum white
        ld      (hl),0x44
        inc     hl
        ld      (hl),0x55
        ld      bc,PALIDX0_P            ; PALIDX = 0x307
        ld      a,7
        out     (c),a
        inc     b
        ld      a,3
        out     (c),a
        ld      b,PALDAT
        in      a,(c)
        cp      0xD7                    ; not written yet
        jp      nz,fail
        inc     hl
        ld      (hl),0x66               ; red
        ld      b,PALIDX0               ; PALIDX0 written: PALDAT back to blue
        ld      a,7
        out     (c),a
        ld      b,PALDAT
        in      a,(c)
        cp      0x44
        jp      nz,fail
        in      a,(c)
        cp      0x55
        jp      nz,fail
        in      a,(c)
        cp      0x66
        jp      nz,fail
        ld      d,0x1E                  ; check 1E: writing PALIDX starts PALDAT at blue again
        ld      b,PALIDX0               ; PALIDX = 0x3FE
        ld      a,0xFE
        out     (c),a
        ld      b,PALDAT
        ld      a,0x99
        out     (c),a                   ; a blue byte, then PALIDX again
        ld      b,PALIDX1
        ld      a,3
        out     (c),a
        ld      b,PALDAT
        ld      a,0x01
        out     (c),a
        ld      a,0x02
        out     (c),a
        ld      a,0x03
        out     (c),a                   ; entry 0x3FE: 01 02 03
        ld      hl,W3+REGS_SPRPALETTE+254*3
        ld      a,(hl)
        cp      0x01
        jp      nz,fail
        inc     hl
        ld      a,(hl)
        cp      0x02
        jp      nz,fail
        inc     hl
        ld      a,(hl)
        cp      0x03
        jp      nz,fail
        ld      d,0x1F                  ; check 1F: L0's registers, PRIO and DMACON after reset
        ld      hl,vr_reset
        ld      c,CUSTPAGE
.rr:    ld      b,(hl)
        inc     hl
        ld      a,b
        cp      0xFF
        jr      z,.rrend
        in      a,(c)
        cp      (hl)
        jp      nz,fail
        inc     hl
        jr      .rr
.rrend: ld      d,0x20                  ; check 20: each written alone, reserved bits read 0
        ld      hl,vr_write
.rw:    ld      b,(hl)
        inc     hl
        ld      a,b
        cp      0xFF
        jr      z,.rwend
        ld      a,(hl)
        inc     hl
        out     (c),a
        in      a,(c)
        cp      (hl)
        jp      nz,fail
        inc     hl
        jr      .rw
.rwend: ld      d,0x21                  ; check 21: BPL0PT: bits 21-1; reading its low byte captures it
        ld      a,0xFF
        ld      b,L0_BPL0PT0
        out     (c),a
        inc     b
        out     (c),a
        inc     b
        out     (c),a
        ld      b,L0_BPL0PT0            ; BPL0PT is 0x3FFFFE: the capture
        in      a,(c)
        cp      0xFE
        jp      nz,fail
        inc     b
        in      a,(c)
        cp      0xFF
        jp      nz,fail
        inc     b
        in      a,(c)
        cp      0x3F
        jp      nz,fail
        ld      a,0x01
        out     (c),a
        in      a,(c)                   ; the captured byte
        cp      0x3F
        jp      nz,fail
        ld      b,L0_BPL0PT0
        in      a,(c)                   ; a new capture
        ld      b,L0_BPL0PT2
        in      a,(c)
        cp      0x01
        jp      nz,fail
        ld      d,0x22                  ; check 22: DMACON sets and clears the bits written as 1
        ld      b,DMACON
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_SPREN_M
        out     (c),a
        in      a,(c)
        cp      DMACON_DMAEN_M | DMACON_SPREN_M
        jp      nz,fail
        ld      a,DMACON_SPREN_M | 0x01 ; clear SPREN; bit 0 is reserved
        out     (c),a
        in      a,(c)
        cp      DMACON_DMAEN_M
        jp      nz,fail
        ld      a,0x7F
        out     (c),a
        in      a,(c)
        or      a
        jp      nz,fail
        ld      b,L0_CTRL0              ; L0 off again
        xor     a
        out     (c),a
        ld      hl,1                    ; window 3 back to SRAM page 1
        ld      b,MMU3_0
        jp      st_map

; Register, value after reset
vr_reset:
        db      L0_CTRL0, 0, L0_CTRL1, 0, L0_CTRL2, 0, L0_CTRL3, 0
        db      L0_WINX0, 0x60, L0_WINX1, 0x03, L0_WINX2, 0x90, L0_WINX3, 0x00     ; XEND 864, XSTART 144
        db      L0_WINY0, 0x71, L0_WINY1, 0x02, L0_WINY2, 0x31, L0_WINY3, 0x00     ; YEND 625, YSTART 49
        db      L0_SCROLLX0, 0, L0_SCROLLX1, 0, L0_BPLSTRIDE0, 0, L0_BPLSTRIDE1, 0
        db      L0_BPL0PT0, 0, L0_BPL0PT1, 0, L0_BPL0PT2, 0
        db      PRIO, 0x24, DMACON, 0
        db      0xFF
; Register, value written, value read back
vr_write:
        db      L0_CTRL0, 0xFE, 0xFC, L0_CTRL1, 0xFF, 0xF3, L0_CTRL2, 0xFF, 0xF0, L0_CTRL3, 0xFF, 0x0F
        db      L0_WINX0, 0xA5, 0xA5, L0_WINX1, 0xFF, 0x07, L0_WINX2, 0x5A, 0x5A, L0_WINX3, 0xFD, 0x05
        db      L0_WINY0, 0x12, 0x12, L0_WINY1, 0xFA, 0x02, L0_WINY2, 0x34, 0x34, L0_WINY3, 0xF9, 0x01
        db      L0_SCROLLX0, 0xFF, 0xFF, L0_SCROLLX1, 0xFF, 0x03
        db      L0_BPLSTRIDE0, 0xFF, 0xFE, L0_BPLSTRIDE1, 0x80, 0x80
        db      L0_WINX0, 0x60, 0x60, L0_WINX1, 0x03, 0x03                        ; the earlier bytes kept
        db      L0_CTRL1, 0x00, 0x00, L0_CTRL0, 0xFE, 0xFC                       ; CTRL1 alone: CTRL0 kept
        db      PRIO, 0xFF, 0x3F, PRIO, 0x24, 0x24
        db      0xFF

        include "selftest.asm"

vidsize: db     0xD0, 0x02, 0x40, 0x02  ; 720, 576
pass:   db      "PASS", 13, 10, 0
failmsg: db     "FAIL ", 0
