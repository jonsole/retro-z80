; retro-z80 boot ROM, phase 1: a memory and MMU self-test, then "hello",
; over the USB serial link. The self-test prints "selftest ok, N MB" (N =
; SYSCFG.CHIPMB) or "selftest FAIL nn" (nn = the check that failed, in hex;
; selftest.asm) and stops there.
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
        jp      start

        ds      0x38 - $, 0xFF
        jp      st_rst38                ; RST 38h: the self-test's register page fetch

start:  ld      sp,0x0000               ; stack grows down from 0xFFFF (SRAM page 5)
        ld      bc,SERCON_P             ; link on, control commands on
        ld      a,SERCON_EN_M | SERCON_CTLEN_M
        out     (c),a
        call    selftest
        jr      z,.ok
        ld      hl,stfail
        call    puts
        ld      a,d                     ; the check that failed
        call    puthex
        jr      .crlf
.ok:    ld      hl,stok
        call    puts
        ld      a,SYSCFG
        in      a,(SYSPAGE)
        rrca                            ; CHIPMB is bits 7-2: 2 or 4
        rrca
        and     SYSCFG_CHIPMB_M >> SYSCFG_CHIPMB_B
        add     a,'0'
        call    putc
        ld      hl,mb
        call    puts
        ld      hl,hello
        call    puts
        jr      stop
.crlf:  ld      hl,crlf
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

; Send A as two hex digits (A, B, C, E changed)
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

        include "selftest.asm"

hello:  db      "hello"
crlf:   db      13, 10, 0
stok:   db      "selftest ok, ", 0
mb:     db      " MB", 13, 10, 0
stfail: db      "selftest FAIL ", 0
