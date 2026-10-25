; retro-z80 boot ROM (spec 16): the RST entry points and ROM calls, the
; start-up, the boot console and the monitor (the shared spec "Monitor and
; upload protocol", docs/spec/monitor.md). Ticket #22: the RST calls and
; the monitor's commands D E F C V S G R P H; ticket #23: the disassembler
; (I) and the memory test (T); ticket #28: G's breakpoint on the debug unit
; and the step N; ticket #29: the loader (U, TARGET 0) and the debug stub;
; the SD card and BASIC come with later tickets.
;
;   Page 0 (0x0000)  the entry table (spec 16, section 3.1), start-up, the
;                    console and keyboard core, the ROM calls, the monitor's
;                    entry and exit, the IM 2 table at 0x1FD0. Always in
;                    window 0 while a program runs
;   Page 1 (0x2000)  the monitor's commands, the rest of start-up, the
;                    self-test, the tape demo
;   Page 2 (0x4000)  the console font (offset 0x4000), the help text, the
;                    disassembler and I, the memory test T
;   Page 3 (0x6000)  the NMI page (spec 16, section 8.6): the NMI's way into
;                    the monitor, assembled at 0x0000, where it runs in
;                    window 0 during an NMI
;
; The raw image is the ROM's 32 KB from offset 0; pages 0-2 are assembled at
; the addresses they have in the monitor's map (ROM page n in window n), so a
; label's value is its offset in the ROM.
;
; Start-up (spec 16, section 4.2) shows its progress as the background
; colour: blue while it starts and the self-test runs (power-on only), green
; while the units, the workspace and the console are set up, black once the
; console is up. A failed self-test: red with white stripes for good (the
; number of stripes is the check's number less 0x40), and "selftest FAIL
; nn" on the serial link.
;
; Assemble: sjasmplus --raw=boot.bin -I ../include boot.asm
;   -DFAILTEST=nn   report check nn as failed (sim/Makefile, failshow)
;   -DKEYWAIT=n     the start-up keys are looked for n ms (250 by default)
;   -DDEVROM        never set ROMLOCK (spec 16, open point B2)

        DEVICE  NOSLOT64K
        include "hw.inc"
        include "rom.inc"

    IFNDEF KEYWAIT
KEYWAIT equ     250
    ENDIF

        ORG     0x0000

; ---------------------------------------------------------------- the entry table
reset:  di
        jp      start
        ds      0x08 - $, 0xFF
        jp      r_putc                  ; RST 08h PUTC
        ds      0x10 - $, 0xFF
        jp      r_getc                  ; RST 10h GETC
        ds      0x18 - $, 0xFF
        jp      r_puts                  ; RST 18h PUTS
        ds      0x20 - $, 0xFF
        jp      r_pollc                 ; RST 20h POLLC
        ds      0x28 - $, 0xFF
        jp      r_call                  ; RST 28h CALL
        ds      0x30 - $, 0xFF
        push    af                      ; RST 30h BREAK
        ld      a,R_BREAK
        jp      monent
        ds      0x38 - $, 0xFF
        jp      r_trap                  ; RST 38h TRAP
        ds      0x40 - $, 0xFF
EXIT:   push    af                      ; EXIT: a program's first return address
        ld      a,R_EXIT
        jp      monent
        ds      0x48 - $, 0xFF
romid:  db      "RZ80", ROM_MAJOR, ROM_MINOR, NFUNC, 0
romdate: db     "2026-10-25", 0         ; ROMDATE (the build's date, by hand)
        ds      0x60 - $, 0
; The NMI page switches window 0 back to page 0 with the OUT just before
; this address (page 3's nmiw0), so its next fetch comes from here
nmiland: jp     ment2
        ds      0x66 - $, 0xFF
        jp      r_nmi                   ; NMI (with NMICTL.EN = 0)

; ---------------------------------------------------------------- start-up
start:  ld      sp,0x0000               ; window 7 (SRAM page 5 after reset)
        ld      ix,0                    ; registers the Z80 leaves undefined at reset
        ld      iy,0                    ; (the ROM calls push IY)
        exx
        ld      bc,0
        ld      de,0
        ld      hl,0
        exx
        ex      af,af'
        xor     a
        ex      af,af'
        ld      hl,col_test             ; blue while it starts
        call    setbg
        ld      bc,VIDCON_P             ; the beam on
        ld      a,VIDCON_EN_M
        out     (c),a
        ld      bc,SERCON_P             ; link on, control commands on, never wait for a PC
        ld      a,SERCON_EN_M | SERCON_CTLEN_M | SERCON_TXDROP_M
        out     (c),a
        ld      bc,RESETWHY_P
        in      a,(c)
        push    af
    IFDEF FAILTEST
        ld      d,FAILTEST
    ELSE
        and     RESETWHY_POWER_M        ; the self-test at power-on only
        jr      z,.skip
        call    selftest                ; (page 1, in window 1 after reset)
        jr      z,.skip
    ENDIF
        ld      hl,stfail
        call    sputs
        ld      a,d                     ; the check that failed
        call    sputhex
        ld      a,13
        out     (SERDATA_PORT),a
        ld      a,10
        out     (SERDATA_PORT),a
        jp      showfail
.skip:  ld      hl,col_ok               ; green while it sets up
        call    setbg
        pop     de                      ; D = RESETWHY
        ld      hl,startmap             ; the monitor's map, windows 1-7
        ld      bc,MMU1_0_P
.map:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7_1 + 1
        jr      nz,.map
        ld      sp,MSTACK
        push    de
        ld      a,high ivt              ; IM 2 with the ROM's table (spec 16, section 6.1)
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low ivt
        out     (c),a
        im      2
        jp      boot2                   ; (page 1)

; Windows 1-7 while the monitor runs: ROM pages 1 and 2, the workspace, the
; console, (any), and the program's pages 6 and 7
startmap:
        dw      PG_ROM1, PG_ROM2, PG_WS, PG_CON, 0x005, 0x006, 0x007

; Send the string at HL over the serial link (A, HL changed)
sputs:  ld      a,(hl)
        or      a
        ret     z
        out     (SERDATA_PORT),a
        inc     hl
        jr      sputs
; Send A as two hex digits (A changed)
sputhex:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a,'0'
        cp      '9' + 1
        jr      c,.o
        add     a,'A' - '9' - 1
.o:     out     (SERDATA_PORT),a
        ret

; ---------------------------------------------------------------- the trap, the NMI
; RST 38h (spec 16, section 7.7): with I = 0 only the self-test runs, and its
; register page fetch comes back to it; otherwise the monitor
r_trap: push    af
        ld      a,i
        jr      z,.st
        ld      a,R_TRAP
        jp      monent
.st:    pop     af
        jp      st_rst38

; The NMI with NMICTL.EN = 0 (spec 16, section 8.6): window 0 is the
; program's, so a few bytes go on its stack, as for a break. The PC is still
; captured: ment2 takes PC and SP from NMICAPPC and NMICAPSP, and G's RETN
; takes the PC from NMICAPPC
r_nmi:  push    af
        ld      a,R_NMI
        jp      monent

; ---------------------------------------------------------------- the monitor's entry
; From a program: A = why (R_...), the program's AF and (but for EXIT) a
; return address on its stack, its map and its other registers as they
; were. Save a frame on the program's stack, map the workspace into window 3
; (or 5, if the stack is in window 3), copy the frame and the MMU registers
; there, then change to the monitor's map and stack (spec 16, section 8.5).
monent: push    hl
        push    bc
        push    de
        ld      e,a                     ; E = why
        ld      bc,DBGCTL_P             ; the debug unit off: the monitor's own code
        xor     a                       ; is never compared (spec 16, section 8.8)
        out     (c),a
        ld      a,i                     ; P/V = IFF2: the program's IFF1; A = I
        di
        push    af                      ; [I, IFF][DE][BC][HL][AF][return]
        ld      hl,-4
        add     hl,sp                   ; the frame will be SP - 4 to SP + 12
        ld      d,MMU3_0
        ld      a,h
        and     0xE0
        cp      0x60
        jr      z,.w5
        ld      bc,15
        add     hl,bc
        ld      a,h
        and     0xE0
        cp      0x60
        jr      nz,.w3
.w5:    ld      d,MMU5_0
.w3:    ld      c,SYSPAGE               ; D = the window for the workspace
        ld      b,d
        in      l,(c)
        inc     b
        in      h,(c)
        push    hl                      ; its read page ...
        ld      a,b
        add     a,MMU0W_0 - MMU0_1
        ld      b,a
        in      l,(c)
        inc     b
        in      h,(c)
        push    hl                      ; ... and write page
        ld      b,d
        ld      a,low PG_WS
        out     (c),a
        inc     b
        ld      a,high PG_WS
        out     (c),a                   ; the workspace there
        ld      a,d
        cp      MMU3_0
        ld      hl,WENT + 18
        jr      z,.d3
        ld      hl,WENT + 18 + 0x4000
.d3:    ld      (hl),d                  ; +18 the window, +19 why
        inc     hl
        ld      (hl),e
        ld      bc,-19
        add     hl,bc
        ex      de,hl                   ; DE = the frame's copy
        ld      hl,0
        add     hl,sp
        ld      bc,16
        ldir                            ; +0 the window's pages, +4 I/IFF, DE, BC, HL, AF, return
        ex      de,hl
        ld      (hl),e                  ; +16: the address just above the frame
        inc     hl
        ld      (hl),d
        ld      de,WMMUT - (WENT + 17)
        add     hl,de                   ; the MMU registers as they are
        ld      bc,MMU0_0_P
.mmu:   in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU7W_1 + 1
        jr      nz,.mmu
        ld      hl,startmap             ; the monitor's map, windows 1-4
        ld      bc,MMU1_0_P
.map:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU4_1 + 1
        jr      nz,.map
        ld      sp,MSTACK
        jp      ment2                   ; (page 1)

; ---------------------------------------------------------------- the monitor's exit
; G's last steps (spec 16, section 8.5), from page 0 because windows 1-7 go
; back to the program's pages. The program's HL, DE, BC, AF and PC are
; already on its stack, below M_SP; everything else is in the workspace.
; After an NMI through the NMI page nothing is on its stack: the last steps
; are the exit's bytes in the save area (gonmi, monitor.asm).
g_final:
        ld      hl,(M_AF2)
        push    hl
        pop     af
        ex      af,af'
        exx
        ld      bc,(M_BC2)
        ld      de,(M_DE2)
        ld      hl,(M_HL2)
        exx
        ld      ix,(M_IX)
        ld      iy,(M_IY)
        ld      a,(M_I)
        ld      i,a
        ld      a,(M_IM)                ; IM as R set it
        bit     6,a
        jr      z,.im
        and     3
        jr      nz,.im1
        im      0
        jr      .im
.im1:   dec     a
        jr      nz,.im2
        im      1
        jr      .im
.im2:   im      2
.im:    ld      hl,(M_SP)
        ld      de,-10
        add     hl,de
        ld      (WENT),hl               ; the program's SP with HL, DE, BC, AF, PC below it
        ld      hl,gwins                ; windows 1, 2, 4-7; window 0 stays ROM page 0
.mmu:   ld      a,(hl)
        inc     hl
        cp      0xFF
        jr      z,.w3
        push    hl
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,M_MMU
        add     hl,de
        add     a,MMU0_0
        ld      b,a
        ld      c,SYSPAGE
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a                   ; the read page (and the write page with it)
        ld      de,15
        add     hl,de
        ld      a,b
        add     a,MMU0W_0 - MMU0_1
        ld      b,a
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a                   ; the write page
        pop     hl
        jr      .mmu
.w3:    ld      a,(M_R)
        ld      r,a
        ld      a,(M_NMI)               ; through the NMI page: out by the save area (gonmi)
        rla
        jr      nc,.w3s
        xor     a
        ld      (M_MON),a
        ld      de,(M_DE)
        jp      NMX_CODE
.w3s:   xor     a
        ld      (M_MON),a               ; the monitor no longer runs
        ld      a,(M_MMU + 6)           ; window 3 last: its four bytes, from the workspace in it
        ld      d,a
        ld      a,(M_MMU + 7)
        ld      e,a
        ld      a,(M_MMU + 16 + 6)
        ld      h,a
        ld      a,(M_MMU + 16 + 7)
        ld      l,a
        ld      sp,(WENT)
        ld      a,(M_IFF)
        ld      c,SYSPAGE
        or      a                       ; NZ: interrupts on (no flag changes from here)
        ld      b,MMU3_0
        out     (c),d
        ld      b,MMU3_1
        out     (c),e
        ld      b,MMU3W_0
        out     (c),h
        ld      b,MMU3W_1
        out     (c),l
        pop     hl
        pop     de
        pop     bc
        jr      nz,.ei
        pop     af
        retn                            ; RETN always (spec 16, section 8.8): a RET with INNMI = 0;
.ei:    pop     af                      ; after an NMI taken with NMICTL.EN = 0, the PC from NMICAPPC
        ei
        retn
gwins:  db      1, 2, 4, 5, 6, 7, 0xFF

; ---------------------------------------------------------------- helpers
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

; Background colours: blue, green, red bytes (BGCOLOR's order)
col_test:  db   0xFF, 0x00, 0x00        ; blue: starting, the self-test
col_ok:    db   0x00, 0xFF, 0x00        ; green: setting up
col_fail:  db   0x00, 0x00, 0xFF        ; red: failed ...
col_white: db   0xFF, 0xFF, 0xFF        ; ... with white stripes
col_black: db   0x00, 0x00, 0x00        ; black: the console's border

stfail: db      "selftest FAIL ", 0

; ---------------------------------------------------------------- interrupts
; The ROM's IM 2 handler for every source (spec 16, section 6.1): turn the
; source that asked off in INTENA, so a source turned on by mistake cannot
; hang a program
ivhand: push    af
        push    bc
        ld      bc,INTID_P
        in      a,(c)
        cp      21
        jr      nc,.done
        ld      b,INTENA0               ; source n: INTENA0 + n / 7, bit n mod 7
.d7:    cp      7
        jr      c,.bit
        sub     7
        inc     b
        jr      .d7
.bit:   ld      c,a
        ld      a,1
        inc     c
.sh:    dec     c
        jr      z,.out
        add     a,a
        jr      .sh
.out:   ld      c,SYSPAGE
        out     (c),a                   ; SETCLR = 0: clear the bit
.done:  pop     bc
        pop     af
        ei
        reti

        include "console.asm"
        include "keys.asm"
        include "calls.asm"
        include "link.asm"              ; frames, CRC-32 and the loader (ticket #29)
        include "stub.asm"              ; the debug stub (ticket #29)

page0_end:
        ASSERT  $ <= 0x1FD0
        ds      0x1FD0 - $, 0xFF
; The IM 2 table: 24 entries, all to ivhand (I = 0x1F, VECBASE = 0xD0)
ivt:    dup     24
        dw      ivhand
        edup
        ASSERT  $ == 0x2000

; ================================================================ page 1
        include "monitor.asm"
        include "selftest.asm"
        include "tape.asm"
page1_end:
        ASSERT  $ <= 0x4000
        ds      0x4000 - $, 0xFF

; ================================================================ page 2
font:   include "font.inc"              ; offset 0x4000: the console font (spec 16, section 5.3)
        include "crctab.asm"            ; the CRC-32 table, 1 KB at 0x4800
        include "help.asm"
        include "disasm.asm"            ; the disassembler (ticket #23)
        include "mondis.asm"            ; I
        include "memtest.asm"           ; T
page2_end:
        ASSERT  $ <= 0x6000
        ds      0x6000 - $, 0xFF

; ================================================================ page 3
; The NMI page (spec 16, section 8.6). With NMICTL.EN and the NMI pages at
; their reset values, an NMI reads window 0 from here (ROM page 3) and
; writes it to the workspace page 0x0FF at the same offsets; the PC and SP
; are in NMICAPPC and NMICAPSP, and nothing has been written on the
; program's stack. Assembled at its address in window 0. After it, the
; sprite demo (sprdemo.asm), run with page 3 in window 2.
        DISP    0x0000
        ds      0x54 - $, 0xFF
; Window 0 back to ROM page 0: the next fetch is page 0's nmiland
nmiw0:  ld      bc,MMU0_0_P
        ld      a,low PG_ROM0
        out     (c),a
        inc     b
        ld      a,high PG_ROM0
        out     (c),a
        ASSERT  $ == nmiland
        ds      0x66 - $, 0xFF
; The NMI: SP, AF, BC and HL into the save area through window 0, then the
; workspace into window 3 (NMISAV3 holds the program's page there)
nmi3:   ld      (NMX_SP - 0x6000),sp
        ld      sp,NMX_SP - 0x6000
        push    af
        push    bc
        push    hl                      ; HL, BC, AF at 0x0EAA-0x0EAF
        ld      bc,MMU3_0_P
        ld      a,low PG_WS
        out     (c),a
        inc     b
        ld      a,high PG_WS
        out     (c),a
        ld      a,(M_MON)
        cp      MON_ON
        jr      z,.mon
        ld      sp,MSTACK               ; free while a program runs
        ld      hl,WMMUT                ; the program's map: NMISAV0-7, NMISAV0W-7W
        ld      bc,NMISAV0_0_P
.sv:    in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        jr      nz,.sv
        ld      hl,(WMMUT + 16 + 6)     ; the entry frame, as monent makes it
        ld      (WENT + 0),hl           ; +0, +2 window 3's pages
        ld      hl,(WMMUT + 6)
        ld      (WENT + 2),hl
        ld      a,i                     ; P/V = IFF2: the program's IFF1
        push    af
        pop     hl
        ld      (WENT + 4),hl
        ld      (WENT + 6),de
        ld      hl,(NMX_BC)
        ld      (WENT + 8),hl
        ld      hl,(NMX_HL)
        ld      (WENT + 10),hl
        ld      hl,(NMX_AF)
        ld      (WENT + 12),hl
        ld      a,MMU3_0
        ld      (WENT + 18),a           ; +18 the workspace's window, +19 why
        ld      a,R_NMI3
        ld      (WENT + 19),a
        ld      hl,.map                 ; the monitor's map, windows 1-4
        ld      bc,MMU1_0_P
.m:     ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      MMU4_1 + 1
        jr      nz,.m
        jp      nmiw0
; The monitor itself was running (spec 16, section 8.8): NMISTAT and
; DBGSTAT cleared, and straight back. A breakpoint in code the monitor runs
; (the unit is live after such a RETN, until the monitor next leaves) fed
; the core a NOP for its first byte: NMICAPPC back by 1, so the instruction
; runs after all (the resume M1 never matches)
.mon:   ld      bc,NMISTAT_P
        in      a,(c)
        out     (c),a
        ld      bc,DBGSTAT_P
        in      a,(c)
        out     (c),a
        and     DBGSTAT_BP0_M | DBGSTAT_BP1_M | DBGSTAT_BP2_M | DBGSTAT_BP3_M
        jr      z,.mr
        ld      bc,NMICAPPC0_P
        in      l,(c)
        inc     b
        in      h,(c)
        dec     hl
        dec     b
        out     (c),l
        inc     b
        out     (c),h
.mr:    ld      sp,NMX_HL
        pop     hl
        pop     bc
        pop     af
        ld      sp,(NMX_SP)
        retn
.map:   dw      PG_ROM1, PG_ROM2, PG_WS, PG_CON
        ENT
        DISP    $ - 0x2000              ; window 2
        include "sprdemo.asm"           ; the sprite demo (ticket #31)
        ENT
page3_end:
        ASSERT  page3_end <= 0x8000
