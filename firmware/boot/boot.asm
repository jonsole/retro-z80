; retro-z80 boot ROM, phase 1: a memory and MMU self-test, then "hello",
; over the USB serial link. The self-test prints "selftest ok, N MB" (N =
; SYSCFG.CHIPMB) or "selftest FAIL nn" (nn = the check that failed, in hex;
; selftest.asm) and stops there.
;
; Progress also shows as the screen's background colour (BGCOLOR, spec 4;
; spec 7, section 5), for a board with no PC attached:
;   no picture   the boot ROM did not get as far as starting the beam
;   blue         the self-test is running (it takes under a millisecond, so
;                a screen that stays blue means the Z80 stopped in it)
;   green        the self-test passed; "hello" was sent
;   red, with white stripes: the self-test failed. The number of stripes
;                is the failing check's number less 0x40 (1 stripe = check
;                41, 2 = check 42 ... 17 = check 51)
; The serial link drops the oldest bytes when nobody reads them (TXDROP), so
; the boot ROM never waits for a PC.
;
; The Z80 starts here at 0x0000, boot ROM page 0 in MMU window 0 (spec 2,
; section 9.4). Windows 2-7 hold SRAM pages 0-5, so the stack at the top of
; window 7 is in SRAM. The boot ROM's real programs (monitor, loader) come
; with spec 16.
;
; Assemble: sjasmplus --raw=boot.bin -I ../include boot.asm
; With -DFAILTEST=nn the self-test is skipped and check nn is shown as
; failed (sim/Makefile, failshow).

        DEVICE  NOSLOT64K
        include "hw.inc"

        ORG     0x0000

reset:  di
        jp      start

        ds      0x38 - $, 0xFF
        jp      st_rst38                ; RST 38h: the self-test's register page fetch

start:  ld      sp,0x0000               ; stack grows down from 0xFFFF (SRAM page 5)
        ld      hl,col_test             ; the screen blue while the self-test runs
        call    setbg
        ld      bc,VIDCON_P             ; the beam on
        ld      a,VIDCON_EN_M
        out     (c),a
        ld      bc,SERCON_P             ; link on, control commands on, never wait for a PC
        ld      a,SERCON_EN_M | SERCON_CTLEN_M | SERCON_TXDROP_M
        out     (c),a
    IFDEF FAILTEST
        ld      d,FAILTEST
        jr      .fail
    ELSE
        call    selftest
        jr      z,.ok
    ENDIF
.fail:  ld      hl,stfail
        call    puts
        ld      a,d                     ; the check that failed
        call    puthex
        ld      hl,crlf
        call    puts
        jp      showfail
.ok:    ld      hl,col_ok               ; the screen green
        call    setbg
        ld      hl,stok
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
stop:   halt                            ; interrupts are off: stays here
        jr      stop

; Send the zero-terminated string at HL (A, B, C, E, HL changed)
puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts

; Send A over USB (the byte is kept in E). With SERCON.TXDROP set, a full
; transmit FIFO drops its oldest byte, so there is no need to wait for room
; (spec 10, section 5.3)
putc:   ld      e,a
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

; Set the background colour from the 3 bytes at HL: blue, green, red; the
; red byte commits it (spec 3, rule 7). A, B, C, HL changed. 97 T-states
; with the RET (showfail counts on it).
setbg:  ld      bc,BGCOLOR0_P           ; 10
        ld      a,(hl)                  ;  7
        out     (c),a                   ; 12  blue
        inc     hl                      ;  6
        inc     b                       ;  4
        ld      a,(hl)                  ;  7
        out     (c),a                   ; 12  green
        inc     hl                      ;  6
        inc     b                       ;  4
        ld      a,(hl)                  ;  7
        out     (c),a                   ; 12  red: the colour changes
        ret                             ; 10

; The self-test failed: show check D on the screen for good. The picture is
; red, with D - 0x40 white stripes from picture line 17 down (lines from 0),
; each 16 lines tall with 16 red lines after it (17 stripes, the most, end
; at line 544). sim/Makefile's failshow checks it.
;
; Timed by counting T-states at 20 MHz (CPUSPEED is 0 after reset): a line
; of 576p is 32 us, 640 T-states. Each frame starts again from the end of
; the vertical blank (VIDSTAT.INVBLANK going to 0 at beam line 49, the first
; picture line), so the stripes stand still. BGCOLOR takes effect at the
; start of a line's picture (spec 4, section 5.6); the writes land about
; half a line after it, so a few T-states of polling jitter never move a
; stripe's edge to another line. A white half (W) and a red half (R = W +
; 16, for DEC E and JR) together are 32 lines: W + R = 20480 T-states.
showfail:
        ld      a,d
        sub     0x40
        ld      d,a                     ; stripes: 1-17
.frame: ld      bc,VIDSTAT_P
.vb:    in      a,(c)
        and     VIDSTAT_INVBLANK_M
        jr      z,.vb                   ; wait for the vertical blank ...
.pic:   in      a,(c)
        and     VIDSTAT_INVBLANK_M
        jr      nz,.pic                 ; ... and for its end: picture line 0
        ld      b,24                    ; half a line (307 T-states)
.half:  djnz    .half
        ld      e,d
.stripe:
        call    wait16                  ; W: 17 + 10091 + 10 + 17 + 97 = 10232
        ld      hl,col_white
        call    setbg                   ; white from the next line
        call    wait16                  ; R: W + 16 = 10248
        ld      hl,col_fail
        call    setbg                   ; red again
        dec     e
        jr      nz,.stripe
        jr      .frame

; 10091 T-states with the RET (B, C, A changed)
wait16: ld      bc,387                  ; 10
.loop:  dec     bc                      ;  6
        ld      a,b                     ;  4
        or      c                       ;  4
        jr      nz,.loop                ; 12, 7 the last time: 26 x 387 - 5
        ld      a,0                     ;  7
        ld      a,0                     ;  7
        ret                             ; 10

        include "selftest.asm"

; Background colours: blue, green, red bytes (BGCOLOR's order)
col_test:  db   0xFF, 0x00, 0x00        ; blue: testing
col_ok:    db   0x00, 0xFF, 0x00        ; green: passed
col_fail:  db   0x00, 0x00, 0xFF        ; red: failed ...
col_white: db   0xFF, 0xFF, 0xFF        ; ... with white stripes

hello:  db      "hello"
crlf:   db      13, 10, 0
stok:   db      "selftest ok, ", 0
mb:     db      " MB", 13, 10, 0
stfail: db      "selftest FAIL ", 0
