; retro-z80 boot ROM, phase 1: "hello" over the USB serial link.
;
; The Z80 starts here at 0x0000, boot ROM page 0 in MMU window 0 (spec 2,
; section 9.4). Windows 2-7 hold SRAM pages 0-5, so the stack at the top of
; window 7 is in SRAM. The boot ROM's real programs (monitor, loader) come
; with spec 16.
;
; Assemble: sjasmplus --raw=boot.bin -I ../include boot.asm

        DEVICE  NOSLOT64K
        include "hw.inc"

        ORG     0x0000

reset:  di
        ld      sp,0x0000               ; stack grows down from 0xFFFF (SRAM page 5)
        ld      bc,SERCON_P             ; link on, control commands on
        ld      a,SERCON_EN_M | SERCON_CTLEN_M
        out     (c),a
        ld      hl,hello
        call    puts
stop:   halt                            ; interrupts are off: stays here
        jr      stop

; Send the zero-terminated string at HL (A, B, C, E, HL changed)
puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts

; Send A over USB (A, B, C changed; the byte is kept in E), as spec 10, 5.2
putc:   ld      e,a
.wait:  ld      a,SERSTAT0              ; TXSPACE
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait                 ; no room yet
        ld      a,e
        out     (SERDATA_PORT),a
        ret

hello:  db      "hello", 13, 10, 0
