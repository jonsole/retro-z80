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
;   green        the self-test passed; "hello" was sent; then, about 20 ms
;                later, the palette chart (chart, below) in the middle, on
;                layer L0, with the green round it
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
        call    chart                   ; the palette chart in L0
stop:   halt                            ; interrupts are off: stays here
        jr      stop

; The palette chart (spec 4; ticket #13): PALETTE0's 256 entries as 16 rows
; of 16 cells on layer L0, an 8-bit bitmap at 2 x 8, in a 512 x 512 window
; in the middle of the screen, with the background (green) round it. Each
; cell is 32 x 32 screen pixels with a black line on its right and bottom
; (entry 0, which is black). Entries 0-15 are the Spectrum colours of the
; default palette (spec 4, section 7.4); 16-231 a 6 x 6 x 6 colour cube
; (red, then green, then blue steps of 51); 232-255 a grey ramp.
;
; The picture: 64 source lines of 256 bytes at SRAM 0x004000 (pages 2-3,
; windows 4-5); chart row r is source lines 4r to 4r + 3, the last black.
; BPLSTRIDE 256 and CTRL2.WRAP 5 (16 KB): the 64 lines are exactly 16 KB,
; so the pointer comes back to 0x004000 at the end of each frame by itself.
; L0 is switched on in the vertical blank, so each frame starts at the top.
CHART   equ     0x8000                  ; window 4: SRAM page 2, physical 0x004000

chart:  ld      hl,CHART
        ld      d,0                     ; the row's first entry: 16 x row
.row:   ld      e,3                     ; three lines of cells ...
.line:  ld      a,d
.cell:  ld      b,15
.px:    ld      (hl),a                  ; 15 pixels of the entry ...
        inc     hl
        djnz    .px
        ld      (hl),0                  ; ... and a black one
        inc     hl
        inc     a
        ld      c,a
        sub     d
        cp      16
        ld      a,c
        jr      nz,.cell
        dec     e
        jr      nz,.line
.blk:   ld      (hl),0                  ; ... and a black line (B = 0: 256 bytes)
        inc     hl
        djnz    .blk
        ld      a,d
        add     a,16
        ld      d,a
        jr      nc,.row
        ; PALETTE0 from entry 16, through PALIDX and PALDAT: blue, green, red
        ld      bc,PALIDX0_P
        ld      a,16
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      b,PALDAT
        ld      h,0                     ; red
.r:     ld      l,0                     ; green
.g:     ld      e,0                     ; blue
.b:     out     (c),e
        out     (c),l
        out     (c),h
        ld      a,e
        add     a,51
        ld      e,a
        jr      nc,.b                   ; 0, 51 ... 255
        ld      a,l
        add     a,51
        ld      l,a
        jr      nc,.g
        ld      a,h
        add     a,51
        ld      h,a
        jr      nc,.r
        ld      a,8                     ; greys 8, 18 ... 238
        ld      e,24
.grey:  out     (c),a
        out     (c),a
        out     (c),a
        add     a,10
        dec     e
        jr      nz,.grey
        ; L0's settings, the layer still off
        ld      hl,l0regs
        ld      c,CUSTPAGE
.reg:   ld      b,(hl)
        inc     hl
        ld      a,b
        cp      0xFF
        jr      z,.on
        ld      a,(hl)
        inc     hl
        out     (c),a
        jr      .reg
.on:    ld      bc,VIDSTAT_P            ; wait for the next frame's start ...
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a
.vb:    in      a,(c)
        rrca
        jr      nc,.vb
        ld      bc,L0_CTRL0_P           ; ... and switch L0 on: 8 bits, 2x across
        ld      a,L_CTRL0_EN_M | (3 << L_CTRL0_BPP_B) | (1 << L_CTRL0_HSCALE_B)
        out     (c),a
        ret

; L0's settings for the chart: register, value
l0regs: db      L0_CTRL1, 3 << L_CTRL1_VSCALE_B                ; 8x down, PALOFS 0
        db      L0_CTRL2, 5 << L_CTRL2_WRAP_B                  ; the pointer wraps in 16 KB
        db      L0_WINX0, 760 & 0xFF, L0_WINX1, 760 >> 8        ; 512 x 512 in the middle:
        db      L0_WINX2, 248, L0_WINX3, 0                      ; beam 248-760 ...
        db      L0_WINY0, 593 & 0xFF, L0_WINY1, 593 >> 8        ; ... x 81-593
        db      L0_WINY2, 81, L0_WINY3, 0
        db      L0_BPLSTRIDE0, 0, L0_BPLSTRIDE1, 1              ; 256
        db      L0_BPL0PT0, 0x00, L0_BPL0PT1, 0x40, L0_BPL0PT2, 0x00    ; 0x004000
        db      DMACON, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BPLEN_M
        db      0xFF

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
