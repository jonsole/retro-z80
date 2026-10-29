; Example 1-2 (docs/guide/system.md): about this machine.
; Reads the system registers through ports and prints what they say: the
; machine's ID, the FPGA build, the SRAM size, why it was last reset, and
; the CPU speed. Then RET goes back to the monitor.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h functions (boot ROM spec, section 7.3)
PUTDEC  equ     0x08

start:  ld      hl,s_id
        rst     0x18                    ; PUTS
        ld      bc,SYSID_P              ; B = register 0x70, C = page 0x00
        in      a,(c)                   ; 0x5A, "Z"
        rst     0x28
        db      PUTHEX

        ld      hl,s_ver
        rst     0x18
        ld      bc,SYSVER_P
        in      a,(c)                   ; major in bits 7-4, minor in 3-0
        rst     0x28
        db      PUTHEX

        ld      hl,s_ram
        rst     0x18
        ld      bc,SYSCFG_P
        in      a,(c)
        rrca                            ; CHIPMB is bits 7-2
        rrca
        and     0x3F
        ld      l,a
        ld      h,0
        rst     0x28
        db      PUTDEC
        ld      hl,s_mb
        rst     0x18

        ld      hl,s_reset              ; RESETWHY: exactly one bit is set
        rst     0x18
        ld      bc,RESETWHY_P
        in      a,(c)
        ld      hl,causes
.cause: rra                             ; the lowest set bit picks the name
        jr      c,.found
        inc     hl
        inc     hl
        jr      .cause
.found: call    puts_at                 ; print the string HL points at

        ld      hl,s_cpu
        rst     0x18
        ld      bc,CPUSPEED_P
        in      a,(c)
        ld      hl,s_spec
        bit     3,a                     ; SPECTRUM: 3.57 MHz
        jr      nz,.speed
        and     CPUSPEED_DIV_M          ; 20 MHz / (DIV + 1)
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,speeds
        add     hl,de
        call    puts_at
        ld      hl,s_mhz
.speed: rst     0x18
        ret                             ; RET goes to the ROM's EXIT

puts_at:                                ; print the string whose address is at (HL)
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        rst     0x18
        ret

s_id:   db      13, 10, "Machine ID   ", 0
s_ver:  db      13, 10, "FPGA build   ", 0
s_ram:  db      13, 10, "SRAM         ", 0
s_mb:   db      " MB", 0
s_reset:db      13, 10, "Last reset   ", 0
s_cpu:  db      13, 10, "CPU          ", 0
s_mhz:  db      " MHz", 13, 10, 0
s_spec: db      "3.57 MHz (Spectrum)", 13, 10, 0

causes: dw      c0, c1, c2, c3, c4, c5, c6, c7
c0:     db      "power-on", 0
c1:     db      "watchdog", 0
c2:     db      "reset button", 0
c3:     db      "software (SYSRESET)", 0
c4:     db      "USB RESET", 0
c5:     db      "USB UPLOAD", 0
c6:     db      "keyboard", 0
c7:     db      "halted", 0

speeds: dw      v0, v1, v2, v3, v4, v5, v6, v7
v0:     db      "20", 0
v1:     db      "10", 0
v2:     db      "6.67", 0
v3:     db      "5", 0
v4:     db      "4", 0
v5:     db      "3.33", 0
v6:     db      "2.86", 0
v7:     db      "2.5", 0
