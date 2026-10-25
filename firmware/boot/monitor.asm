; The monitor (the shared spec "Monitor and upload protocol", sections 2-4;
; spec 16, section 8), in ROM page 1, included by boot.asm: the rest of
; start-up, the monitor's entry from a program, the command line and the
; commands D E F C V S G R P H.
;
; It runs in the monitor's map (spec 16, section 5.2) with interrupts off:
; ROM pages 0-2 in windows 0-2, the workspace (page 0x0FF) in window 3 with
; the stack at its top, the console (page 0x0FE) in window 4, the access
; window 5 for the memory a command looks at. It prints and reads keys
; through the RST calls, like a program. IX points into the line being
; read. Errors print "? ..." and go back to the prompt, with the stack set
; again.

; ================================================================ start-up, continued
; From boot.asm's start: the monitor's map, SP in the workspace with
; RESETWHY on it, IM 2 (spec 16, section 4.2, steps 4-8)
boot2:  call    units                   ; step 4: every unit as a program finds it
        call    minit                   ; the workspace
        call    fontcp
        call    coninit                 ; step 5: the console
        ld      hl,col_black
        call    setbg
        pop     de                      ; D = RESETWHY
        push    de
        call    signon
        call    keys                    ; step 6: the start-up keys, E: bit 0 M, 1 U, 2 D
        pop     af
        push    de
        and     RESETWHY_POWER_M        ; step 7: ROMLOCK at power-on, unless D
        jr      z,.lk
    IFNDEF DEVROM
        bit     2,e
        jr      nz,.dev
        ld      bc,SYSCON_P
        in      a,(c)
        or      SYSCON_ROMLOCK_M
        out     (c),a
        jr      .lk
    ENDIF
.dev:   call    pmsg
        db      "Development: the boot ROM is left writable.", 13, 10, 0
.lk:    pop     de
        bit     1,e                     ; step 8: U (or UPLOAD): the loader, not built yet
        jr      z,.mon
        call    pmsg
        db      "The loader comes with the FT232H (ticket #24).", 13, 10, 0
.mon:   call    pmsg
        db      "Monitor.  H for help.", 13, 10, 0
        jp      mloop

; The sign-on lines (shared spec, section 2.3); D = RESETWHY
signon: push    de
        call    pmsg
        db      "retro-z80 boot ROM ", '0' + ROM_MAJOR, '.', '0' + ROM_MINOR, "  Z80 at ", 0
        ld      bc,CPUSPEED_P           ; the speed CPUSPEED gives
        in      a,(c)
        bit     CPUSPEED_SPECTRUM_B,a
        ld      hl,cspeed_s
        jr      nz,.spd
        and     CPUSPEED_DIV_M          ; HL = cspeed + 5 x DIV
        ld      l,a
        add     a,a
        add     a,a
        add     a,l
        ld      l,a
        ld      h,0
        ld      bc,cspeed
        add     hl,bc
.spd:   rst     18h
        call    pmsg
        db      " MHz, ", 0
        ld      bc,SYSCFG_P
        in      a,(c)
        rrca
        rrca
        and     SYSCFG_CHIPMB_M >> SYSCFG_CHIPMB_B
        add     a,'0'
        rst     08h
        call    pmsg
        db      " MB SRAM", 13, 10, "Reset: ", 0
        pop     de
        push    de
        ld      hl,cwhy                 ; the cause: the lowest bit set
        ld      a,d
        or      a
        jr      z,.why
.wb:    rrca
        jr      c,.why
        push    af
.ws:    ld      a,(hl)
        inc     hl
        or      a
        jr      nz,.ws
        pop     af
        jr      .wb
.why:   rst     18h
        pop     de
        bit     0,d
        jr      z,.nst
        call    pmsg
        db      ".  Self-test ok", 0
.nst:   call    pmsg
        db      ".", 13, 10, 0
        ret
cwhy:   db      "power-on", 0, "watchdog", 0, "button", 0, "software", 0
        db      "USB", 0, "upload", 0, "keyboard", 0, "halted", 0
cspeed: db      "20", 0, 0, 0                           ; CPUSPEED.DIV 0-7, 5 bytes each
        db      "10", 0, 0, 0
        db      "6.67", 0
        db      "5", 0, 0, 0, 0
        db      "4", 0, 0, 0, 0
        db      "3.33", 0
        db      "2.86", 0
        db      "2.5", 0, 0
cspeed_s: db    "3.57", 0                               ; CPUSPEED.SPECTRUM

; The start-up keys (spec 16, section 4.3), looked for KEYWAIT ms: M, U, D
; on the membrane (KEYMAP) or the PS/2 keyboard (its repeats), the DivMMC
; button for M; RESETWHY.UPLOAD (D) counts as U. E = bit 0 M, 1 U, 2 D
keys:   ld      e,0
        bit     5,d                     ; RESETWHY.UPLOAD
        jr      z,.t0
        set     1,e
.t0:    call    ktime
        ld      (T_I),hl
.look:  ld      bc,KEYMAP2_P            ; M: column 2 row 7, D: column 2 row 1
        in      a,(c)
        bit     7,a
        jr      z,.k1
        set     0,e
.k1:    bit     1,a
        jr      z,.k2
        set     2,e
.k2:    inc     b                       ; U: column 3 row 5
        in      a,(c)
        bit     5,a
        jr      z,.k3
        set     1,e
.k3:    ld      bc,SYSBTN_P
        in      a,(c)
        and     SYSBTN_DIVMMC_M
        jr      z,.k4
        set     0,e
.k4:    ld      bc,KBSTAT_P             ; PS/2 bytes: M 3A, U 3C, D 23 (released ones too)
        in      a,(c)
        and     KBSTAT_COUNT_M
        jr      z,.time
        in      a,(KBDATA_PORT)
        cp      0x3A
        jr      nz,.k5
        set     0,e
.k5:    cp      0x3C
        jr      nz,.k6
        set     1,e
.k6:    cp      0x23
        jr      nz,.k4
        set     2,e
        jr      .k4
.time:  call    ktime
        ld      bc,(T_I)
        or      a
        sbc     hl,bc
        ld      bc,(KEYWAIT * 1000 + 255) / 256
        or      a
        sbc     hl,bc
        jr      c,.look
        ret

; Every unit as a program finds it (spec 16, section 6): the ROM writes them
; itself, so a jump to 0 is a clean start too
units:  ld      hl,unitab
.u:     ld      c,(hl)
        inc     hl
        ld      b,(hl)
        inc     hl
        ld      a,b
        and     c
        inc     a
        ret     z                       ; 0xFFFF ends it
        ld      a,(hl)
        inc     hl
        out     (c),a
        jr      .u
unitab: dw      INTCON_P
        db      0
        dw      INTENA0_P
        db      0x7F                    ; SETCLR = 0: every source off
        dw      INTENA1_P
        db      0x7F
        dw      INTENA2_P
        db      0x7F
        dw      TMR0_CTRL_P
        db      0
        dw      TMR1_CTRL_P
        db      0
        dw      TMR2_CTRL_P
        db      0
        dw      TMR3_CTRL_P
        db      0
        dw      WDCTRL_P
        db      0
        dw      SERIRQEN_P
        db      0
        dw      KBCON_P
        db      KBCON_EN_M
        dw      KBIRQEN_P
        db      0
        dw      NMICON_P
        db      NMICON_BUTTONEN_M | NMICON_USBEN_M
        dw      NMICTL_P
        db      NMICTL_EN_M | NMICTL_CAPTURE_M
        dw      IPCTL_P                 ; the interrupt pages off (spec 2, section 9.8)
        db      0
        dw      IPMASK_P
        db      0
        dw      IPDEPTH_P
        db      0
        dw      CPUSPEED_P
        db      0
        dw      COPCON_P
        db      0
        dw      PRIO_P
        db      0x24
        dw      0xFFFF

; The workspace's state as at start-up: no program yet, PC 8000
minit:  ld      hl,WSTATE
        ld      b,0
.clr:   ld      (hl),0
        inc     hl
        djnz    .clr
        ld      hl,'R' + ('Z' << 8)
        ld      (M_MARK),hl
        ld      hl,0x8000
        ld      (M_PC),hl
        ld      (M_ENTRY),hl
        ld      hl,0xFFFE
        ld      (M_SP),hl
        ld      a,2
        ld      (M_IM),a
        ld      a,high ivt
        ld      (M_I),a
        ld      hl,progmap              ; the program map (spec 16, section 5.1)
        ld      de,M_MMU
        ld      bc,32
        ldir
        ld      a,1
        ld      (M_DSZ),a
        ret
progmap: dw     PG_ROM0, 1, 2, 3, 4, 5, 6, 7
        dw      PG_ROM0, 1, 2, 3, 4, 5, 6, 7

; The font from ROM page 2 to the workspace (PATPT 0x1FE000)
fontcp: ld      hl,font
        ld      de,WFONT
        ld      bc,256 * 8
        ldir
        ret

; The console from nothing: the map cleared, the state, L0 and its colour
; pairs (spec 7, section 5.1)
coninit:
        ld      (T_I),sp                ; the whole map: spaces in pair 0, 4096
        ld      sp,CMAP + 0x2000        ; entries pushed from the top down
        ld      hl,' ' + (PAIR0 << 8)
        ld      b,0
.fill:
        dup     16
        push    hl
        edup
        djnz    .fill
        ld      sp,(T_I)
        ld      hl,CMAP + 0xC0          ; the state: zeros, then
        ld      b,64
.s:     ld      (hl),0
        inc     hl
        djnz    .s
        ld      ix,CMAP + 0xC0
        ld      (ix+CS_MARK),0x5A
        ld      (ix+CS_ATTR),PAIR0
        ld      (ix+CS_MODE),0x0F       ; screen, serial, keyboards, serial keys
        ld      (ix+CS_BASE),high CMAP
        ld      bc,KEYMAP0_P            ; keys held now are not typed
        ld      hl,CMAP + 0xC0 + CS_MPREV
.km:    in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        ld      a,b
        cp      KEYMAP6 + 1
        jr      nz,.km
        xor     a
        ld      (CMAP + 0x1C0),a        ; no last line
        ; on into conl0
; L0 as the console, in front, its pairs in PALETTE0, the border black
conl0:  ld      bc,L0_CTRL0_P           ; off while it is set up
        xor     a
        out     (c),a
        ld      hl,c0regs
        ld      c,CUSTPAGE
.reg:   ld      b,(hl)
        inc     hl
        ld      a,b
        cp      0xFF
        jr      z,.sy
        ld      a,(hl)
        inc     hl
        out     (c),a
        jr      .reg
.sy:    ld      a,(CMAP + 0xC0 + CS_TOP)
        add     a,a
        add     a,a
        add     a,a
        ld      bc,L0_SCROLLY0_P
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      hl,cpal
        call    palput
        ld      bc,DMACON_P             ; the fetch on
        ld      a,0x7F
        out     (c),a
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BPLEN_M
        out     (c),a
        ld      bc,PRIO_P
        ld      a,0x24
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,VIDCON_P
        ld      a,VIDCON_EN_M
        out     (c),a
        ld      hl,col_black
        call    setbg
        xor     a                       ; port 0xFE: border black (as BGCOLOR now), beeper 0
        out     (ULA_PORT),a
        ld      bc,L0_CTRL0_P           ; on: 1 bit, tile map, 1x across
        ld      a,L_CTRL0_EN_M | L_CTRL0_MODE_M
        out     (c),a
        ret

; The 15 colour pairs to PALETTE0 from HL (paper, ink; each blue, green,
; red), or from PALETTE0 to HL (palget). A, B, C, D, E, HL changed
palput: ld      e,16
.p:     call    palidx
        ld      d,6
.b:     ld      a,(hl)
        out     (c),a
        inc     hl
        dec     d
        jr      nz,.b
        call    .nx
        jr      nz,.p
        ret
.nx:    ld      a,e
        add     a,16
        ld      e,a
        ret                             ; Z after entry 240 + 16
palget: ld      e,16
.p:     call    palidx
        ld      d,6
.b:     in      a,(c)
        ld      (hl),a
        inc     hl
        dec     d
        jr      nz,.b
        call    palput.nx
        jr      nz,.p
        ret
palidx: ld      bc,PALIDX0_P            ; PALETTE0 entry E; BC = PALDAT's port
        out     (c),e
        inc     b
        xor     a
        out     (c),a
        ld      b,PALDAT
        ret

; L0's settings for the console: register, value
c0regs: db      L0_CTRL1, 1 << L_CTRL1_VSCALE_B                ; 2x down, PALOFS 0
        db      L0_CTRL2, 0
        db      L0_CTRL3, 2 << L_CTRL3_MAPW_B                  ; 128 x 32 entries
        db      L0_WINX0, 824 & 0xFF, L0_WINX1, 824 >> 8        ; 640 x 480 in the middle:
        db      L0_WINX2, 184, L0_WINX3, 0                      ; beam 184-824 ...
        db      L0_WINY0, 577 & 0xFF, L0_WINY1, 577 >> 8        ; ... x 97-577
        db      L0_WINY2, 97, L0_WINY3, 0
        db      L0_SCROLLX0, 0, L0_SCROLLX1, 0
        db      L0_MAPPT0, 0x00, L0_MAPPT1, 0xC0, L0_MAPPT2, 0x1F       ; 0x1FC000
        db      L0_PATPT0, 0x00, L0_PATPT1, 0xE0, L0_PATPT2, 0x1F       ; 0x1FE000
        db      0xFF

; The pairs 0-14: paper, then ink, each blue, green, red
cpal:   db      0x00, 0x00, 0x00,  0xD7, 0xD7, 0xD7     ; 0: light grey on black
        db      0x00, 0x00, 0x00,  0xFF, 0xFF, 0xFF     ; 1: white on black
        db      0x00, 0x00, 0x00,  0x00, 0xFF, 0x00     ; 2: green on black
        db      0xD7, 0xD7, 0xD7,  0x00, 0x00, 0x00     ; 3: black on light grey
        db      0x00, 0x00, 0x00,  0x00, 0x00, 0xFF     ; 4: red on black
        db      0x00, 0x00, 0x00,  0x00, 0xFF, 0xFF     ; 5: yellow on black
        db      0x00, 0x00, 0x00,  0xFF, 0xFF, 0x00     ; 6: cyan on black
        db      0x00, 0x00, 0x00,  0xFF, 0x00, 0xFF     ; 7: magenta on black
        db      0x00, 0x00, 0x00,  0xFF, 0x7F, 0x3F     ; 8: light blue on black
        db      0xFF, 0xFF, 0xFF,  0x00, 0x00, 0x00     ; 9: black on white
        db      0xAA, 0x00, 0x00,  0xFF, 0xFF, 0xFF     ; 10: white on blue
        db      0x00, 0xAA, 0x00,  0x00, 0x00, 0x00     ; 11: black on green
        db      0x00, 0x00, 0xAA,  0xFF, 0xFF, 0xFF     ; 12: white on red
        db      0x00, 0xFF, 0xFF,  0x00, 0x00, 0x00     ; 13: black on yellow
        db      0xFF, 0xFF, 0x00,  0x00, 0x00, 0x00     ; 14: black on cyan

; ================================================================ entry from a program
; From monent (boot.asm): the monitor's map and stack; the frame at WENT,
; the MMU registers as found at WMMUT
ment2:  ld      a,(WENT + 18)           ; the workspace's window had the program's pages
        sub     MMU0_0
        ld      e,a
        ld      d,0
        ld      hl,WMMUT
        add     hl,de
        ld      de,(WENT + 2)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        ld      de,15
        add     hl,de
        ld      de,(WENT + 0)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        ld      (T_DBUF),ix             ; registers not in the frame, kept aside
        ld      (T_DBUF + 2),iy         ; until the state is known good
        exx
        ld      (T_DBUF + 4),bc
        ld      (T_DBUF + 6),de
        ld      (T_DBUF + 8),hl
        exx
        ex      af,af'
        push    af
        ex      af,af'
        pop     hl
        ld      (T_DBUF + 10),hl
        ld      a,r
        ld      (T_DBUF + 12),a
        xor     a
        ld      (T_FLAG),a
        call    wscheck                 ; a program may have spoilt the workspace
        jr      z,.ok
        call    minit
        ld      a,1
        ld      (T_FLAG),a              ; 1: the workspace was set up again
.ok:    ld      hl,T_DBUF
        ld      de,M_IX
        ld      bc,4
        ldir                            ; IX, IY
        ld      de,M_BC2
        ld      c,6
        ldir                            ; BC', DE', HL'
        ld      hl,(T_DBUF + 10)
        ld      (M_AF2),hl
        ld      a,(T_DBUF + 12)
        ld      (M_R),a
        call    fontcp
        ld      a,(CMAP + 0xC0 + CS_MARK)
        cp      0x5A
        jr      z,.con
        call    coninit
        ld      a,1
        ld      (T_FLAG),a
        xor     a
        ld      (M_TAKEN),a             ; (the console was the program's screen)
.con:   ld      hl,(WENT + 4)           ; I and IFF
        ld      a,h
        ld      (M_I),a
        ld      a,l
        and     4                       ; P/V
        rrca
        rrca
        ld      (M_IFF),a
        ld      hl,(WENT + 6)
        ld      (M_DE),hl
        ld      hl,(WENT + 8)
        ld      (M_BC),hl
        ld      hl,(WENT + 10)
        ld      (M_HL),hl
        ld      hl,(WENT + 12)
        ld      (M_AF),hl
        ld      hl,WMMUT
        ld      de,M_MMU
        ld      bc,32
        ldir
        ld      bc,CPUSPEED_P           ; the monitor runs at 20 MHz
        in      a,(c)
        ld      (M_SPEED),a
        xor     a
        out     (c),a
        ld      hl,M_IM                 ; the program has run
        set     7,(hl)
        ld      a,(WENT + 19)
        ld      (M_WHY),a
        ld      hl,(WENT + 16)          ; just above the frame
        cp      R_EXIT
        jr      nz,.rst
        dec     hl                      ; EXIT had no return address
        dec     hl
        ld      (M_SP),hl
        ld      hl,EXIT
        ld      (M_PC),hl
        xor     a
        ld      (M_RUN),a
        jr      .bp
.rst:   ld      (M_SP),hl
        ld      hl,(WENT + 14)
        ld      (M_PC),hl
        ld      (M_SHOW),hl
        ld      a,1
        ld      (M_RUN),a
        ld      a,(M_WHY)
        cp      R_NMI
        jr      z,.bp
        dec     hl                      ; the RST's own address
        ld      (M_SHOW),hl
        cp      R_TRAP
        jr      z,.pc
        cp      R_FBREAK
        jr      nz,.bk
        dec     hl                      ; RST 28h and its number
        ld      (M_SHOW),hl
        jr      .bp
.bk:    ld      a,(M_BPON)              ; RST 30h: the breakpoint?
        or      a
        jr      z,.bp
        ld      de,(M_BPADR)
        or      a
        sbc     hl,de
        jr      nz,.bp
        ld      a,R_BKPT
        ld      (M_WHY),a
        ex      de,hl
.pc:    ld      (M_PC),hl               ; PC at the trap's or the breakpoint's byte
.bp:    call    bpclr                   ; the breakpoint out of the program
        call    takescr
        call    wdkick
        call    bol
        ld      a,(T_FLAG)
        or      a
        jr      z,.msg
        call    pmsg
        db      "The workspace or the console was set up again.", 13, 10, 0
.msg:   ld      a,(M_WHY)
        ld      hl,s_ended
        cp      R_EXIT
        jr      z,.m1
        ld      hl,s_break
        cp      R_BREAK
        jr      z,.m2
        cp      R_FBREAK
        jr      z,.m2
        ld      hl,s_bkpt
        cp      R_BKPT
        jr      z,.m2
        ld      hl,s_trap
        cp      R_TRAP
        jr      z,.m2
        ld      hl,s_nmi
.m2:    rst     18h
        ld      hl,(M_SHOW)
        rst     28h
        db      7                       ; PUTHEX16
        jr      .m3
.m1:    rst     18h
.m3:    call    pnl
        call    showregs
        jp      mloop
s_break: db     "Break at ", 0
s_bkpt: db      "Breakpoint at ", 0
s_trap: db      "Trap RST 38h at ", 0
s_nmi:  db      "NMI at ", 0
s_ended: db     "Program ended.", 0

; The breakpoint's old byte back, if it is set
bpclr:  ld      a,(M_BPON)
        or      a
        ret     z
        xor     a
        ld      (M_BPON),a
        ld      hl,(M_BPADR)
        call    setcpu
        ld      a,(M_BPOLD)
        jp      wrb

; Z if the workspace's state has its marker and its sum
wscheck:
        ld      hl,(M_MARK)
        ld      de,'R' + ('Z' << 8)
        or      a
        sbc     hl,de
        ret     nz
        call    wssum
        ld      de,(M_SUM)
        or      a
        sbc     hl,de
        ret
; HL = the sum of the state's bytes after M_SUM
wssum:  ld      hl,0
        ld      de,M_WHY
        ld      b,WSTATE_END - M_WHY
.s:     ld      a,(de)
        add     a,l
        ld      l,a
        jr      nc,.n
        inc     h
.n:     inc     de
        djnz    .s
        ret

; ---- Taking the screen (spec 16, section 8.5): keep L0's registers, PRIO,
; DMACON, BGCOLOR, COPCON, VIDCON, PALIDX and the console's colour pairs,
; then L0 back as the console
takescr:
        ld      a,(M_TAKEN)
        or      a
        jr      nz,.con
        ld      hl,M_VID
        ld      bc,L0_CTRL0_P
.l0:    in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        ld      a,b
        cp      L0_CTRL0 + 32
        jr      nz,.l0
        ld      de,vidregs
.v:     ld      a,(de)
        inc     de
        ld      b,a
        ld      a,(de)
        inc     de
        ld      c,a
        and     b
        inc     a
        jr      z,.pal
        in      a,(c)
        ld      (hl),a
        inc     hl
        jr      .v
.pal:   ld      hl,WPAL
        call    palget
        ld      hl,CMAP + 0xC0 + CS_MODE ; the program's CONMODE and colour pair,
        ld      a,(hl)                  ; then the monitor's: all on, pair 0
        ld      (M_VID + 41),a
        ld      (hl),0x0F
        ld      hl,CMAP + 0xC0 + CS_ATTR
        ld      a,(hl)
        ld      (M_VID + 42),a
        ld      (hl),PAIR0
        ld      a,1
        ld      (M_TAKEN),a
.con:   jp      conl0
; The registers after L0's: register, page
vidregs: db     PRIO, CUSTPAGE, DMACON, CUSTPAGE, BGCOLOR0, CUSTPAGE, BGCOLOR1, CUSTPAGE
        db      BGCOLOR2, CUSTPAGE, low COPCON, CUSTPAGE + 1, VIDCON, CUSTPAGE
        db      PALIDX0, CUSTPAGE, PALIDX1, CUSTPAGE, 0xFF, 0xFF

; ... and giving it back, before G
givescr:
        ld      a,(M_TAKEN)
        or      a
        ret     z
        xor     a
        ld      (M_TAKEN),a
        ld      hl,WPAL
        call    palput
        ld      hl,M_VID + 1            ; L0's registers, CTRL0 last
        ld      bc,L0_CTRL1_P
.l0:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      L0_CTRL0 + 32
        jr      nz,.l0
        ld      a,(M_VID)
        ld      b,L0_CTRL0
        out     (c),a
        ld      a,(M_VID + 32)
        ld      bc,PRIO_P
        out     (c),a
        ld      b,DMACON
        ld      a,0x7F
        out     (c),a
        ld      a,(M_VID + 33)
        or      DMACON_SETCLR_M
        out     (c),a
        ld      hl,M_VID + 34
        call    setbg
        ld      a,(M_VID + 37)
        ld      bc,COPCON_P
        out     (c),a
        ld      a,(M_VID + 38)
        ld      bc,VIDCON_P
        out     (c),a
        ld      a,(M_VID + 39)
        ld      b,PALIDX0
        out     (c),a
        ld      a,(M_VID + 40)
        inc     b
        out     (c),a
        ld      a,(M_VID + 41)
        ld      (CMAP + 0xC0 + CS_MODE),a
        ld      a,(M_VID + 42)
        ld      (CMAP + 0xC0 + CS_ATTR),a
        ret

; ================================================================ the command line
mloop:  ld      sp,MSTACK
        ld      a,'>'
        rst     08h
        ld      a,' '
        rst     08h
        ld      hl,LBUF
        ld      b,LBUFSZ
        ld      e,1                     ; a Tab on an empty line: the tape demo
        call    gline
        ld      a,e
        cp      27
        jr      z,mloop
        cp      9
        jr      nz,.line
        call    pnl
        call    tape                    ; Tab or EDIT: the port 0xFE demo (ticket #21)
        jr      mloop
.line:  ld      ix,LBUF
        xor     a
        ld      (T_SZSET),a
        inc     a
        ld      (T_SIZE),a
        call    pskip
        jr      z,.empty
        inc     ix
        ld      hl,ctab
.find:  ld      b,(hl)                  ; the command letter
        inc     hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        inc     b
        dec     b
        jp      z,e_syntax
        cp      b
        jr      nz,.find
        push    de
        ld      a,(ix+0)                ; a size: .B .W .L
        cp      '.'
        jr      nz,.go
        inc     ix
        call    pchar
        inc     ix
        ld      b,1
        cp      'B'
        jr      z,.sz
        inc     b
        cp      'W'
        jr      z,.sz
        ld      b,4
        cp      'L'
        jp      nz,e_syntax
.sz:    ld      a,b
        ld      (T_SIZE),a
        ld      a,1
        ld      (T_SZSET),a
.go:    xor     a
        ld      (M_LAST),a
        ret                             ; to the command
.empty: ld      a,(M_LAST)              ; Enter after D or S: carry on
        cp      'D'
        jp      z,c_dump.more
        cp      'S'
        jp      z,c_search.more
        jp      mloop

ctab:   db      'D'
        dw      c_dump
        db      'E'
        dw      c_enter
        db      'F'
        dw      c_fill
        db      'C'
        dw      c_copy
        db      'V'
        dw      c_compare
        db      'S'
        dw      c_search
        db      'G'
        dw      c_go
        db      'R'
        dw      c_regs
        db      'P'
        dw      c_port
        db      'H'
        dw      c_help
        db      '?'
        dw      c_help
        db      'I'
        dw      e_notyet
        db      'T'
        dw      e_notyet
        db      'U'
        dw      e_notyet
        db      'L'
        dw      e_notyet
        db      'B'
        dw      e_notyet
        db      'X'
        dw      e_notyet
        db      0

; ---- Errors: "? reason" on a line of its own, then the prompt
e_syntax:
        ld      hl,s_syntax
        jr      merr
e_addr: ld      hl,s_addr
        jr      merr
e_size: ld      hl,s_size
        jr      merr
e_notyet:
        ld      hl,s_notyet
merr:   ld      sp,MSTACK
        push    hl
        call    bol
        pop     hl
        rst     18h
        call    pnl
        xor     a
        ld      (M_LAST),a
        jp      mloop
s_syntax: db    "? syntax", 0
s_addr: db      "? address", 0
s_size: db      "? size", 0
s_notyet: db    "? not yet: a later ticket", 0

; ---- Reading the line (IX)
; A = the character at IX in upper case
pchar:  ld      a,(ix+0)
        cp      'a'
        ret     c
        cp      'z' + 1
        ret     nc
        sub     0x20
        ret
; Skip spaces and commas: A = the next character, Z at the end of the line
pskip:  call    pchar
        cp      ' '
        jr      z,.n
        cp      ','
        jr      z,.n
        or      a
        ret
.n:     inc     ix
        jr      pskip
; The end of the line, or ? syntax
pend:   call    pskip
        ret     z
        jp      e_syntax
; A hex number of 1-8 digits into T_NUM (32 bits): carry if there is none
pnum:   call    pskip
        ld      hl,0
        ld      (T_NUM),hl
        ld      (T_NUM + 2),hl
        call    hexdig
        ret     c
        ld      b,0                     ; digits
.d:     inc     b
        ld      a,b
        cp      9
        jp      nc,e_syntax
        ld      a,c
        ld      hl,T_NUM                ; T_NUM x 16 + the digit
        ld      e,4
.x16:   sla     (hl)
        inc     hl
        rl      (hl)
        inc     hl
        rl      (hl)
        inc     hl
        rl      (hl)
        dec     hl
        dec     hl
        dec     hl
        dec     e
        jr      nz,.x16
        or      (hl)
        ld      (hl),a
        inc     ix
        call    hexdig
        jr      nc,.d
        cp      ' '                     ; a number ends at a space, a comma or the end
        jr      z,.ok
        cp      ','
        jr      z,.ok
        or      a
        jp      nz,e_syntax
.ok:    or      a
        ret
; C = the hex digit at IX (A = the character), or carry
hexdig: call    pchar
        ld      c,a
        sub     '0'
        jr      c,.no
        cp      10
        jr      c,.y
        sub     'A' - '0'
        jr      c,.no
        cp      6
        jr      nc,.no
        add     a,10
.y:     ld      c,a
        or      a
        ret
.no:    ld      a,c
        scf
        ret
; A number that must be given: into T_NUM
pnumr:  call    pnum
        ret     nc
        jp      e_syntax
; An address, with P in front for a physical one: T_NUM = the address,
; T_NUM + 3 bit 0 = physical. ? syntax if there is none
paddr:  call    pskip
        ld      c,0
        cp      'P'
        jr      nz,.n
        inc     ix
        inc     c
.n:     push    bc
        call    pnumr
        pop     bc
        ld      a,(T_NUM + 3)
        or      a
        jp      nz,e_addr
        ld      a,(T_NUM + 2)
        bit     0,c
        jr      nz,.p
        or      a                       ; a CPU address: 0000-FFFF
        jp      nz,e_addr
        ret
.p:     cp      0x80                    ; P000000-P7FFFFF
        jp      nc,e_addr
        ld      a,1
        ld      (T_NUM + 3),a
        ret
; A CPU address only (code: G)
pcpu:   call    paddr
        ld      a,(T_NUM + 3)
        or      a
        ret     z
        jp      e_addr
; A count into T_CNT (24 bits); it must be a whole number of items
pcount: call    pnumr
        ld      a,(T_NUM + 3)
        or      a
        jp      nz,e_syntax
        ld      hl,(T_NUM)
        ld      (T_CNT),hl
        ld      a,(T_NUM + 2)
        ld      (T_CNT + 2),a
        ld      a,(T_SIZE)
        dec     a
        and     l
        ret     z
        jp      e_size
; T_NUM to the 4 bytes at DE
tnum:   ld      hl,T_NUM
        ld      bc,4
        ldir
        ret
; Values to the end of the line, into T_VAL (T_VLEN bytes): numbers of the
; access size, low byte first, and strings in double quotes
pvals:  xor     a
        ld      (T_VLEN),a
.next:  call    pskip
        jr      z,.end
        cp      '"'
        jr      z,.str
        call    pnumr
        ld      a,(T_SIZE)              ; the value must fit the size
        ld      b,a
        ld      hl,T_NUM + 3
        ld      c,4
.fit:   ld      a,c
        cp      b
        jr      z,.put
        ld      a,(hl)
        or      a
        jp      nz,e_syntax
        dec     hl
        dec     c
        jr      .fit
.put:   ld      hl,T_NUM
.pb:    ld      a,(hl)
        call    .add
        inc     hl
        djnz    .pb
        jr      .next
.str:   inc     ix
.sc:    ld      a,(ix+0)
        or      a
        jp      z,e_syntax              ; no closing quote
        inc     ix
        cp      '"'
        jr      z,.next
        call    .add
        jr      .sc
.end:   ld      a,(T_VLEN)
        or      a
        ret     nz
        jp      e_syntax
.add:   push    hl
        push    af
        ld      a,(T_VLEN)
        cp      T_VMAX
        jp      nc,e_syntax
        ld      l,a
        inc     a
        ld      (T_VLEN),a
        ld      h,high T_VAL
        ld      a,l
        add     a,low T_VAL
        ld      l,a
        pop     af
        ld      (hl),a
        pop     hl
        ret

; ================================================================ memory
; Map the byte at T_CUR into the access window: C = 0 to read it, 1 to
; write it. HL = its address in window 5; carry if it is a register whose
; read has side effects (spec 16, section 8.1). ? address where the machine
; forbids it. A, B, C, D, E changed
xlat:   ld      a,(T_CUR + 3)
        rrca
        jr      c,.phys
        ld      a,(T_CUR + 1)           ; a CPU address: the program's page for its window
        rlca
        rlca
        rlca
        and     7
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,M_MMU
        bit     0,c
        jr      z,.r
        ld      hl,M_MMU + 16
.r:     add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        bit     0,c
        call    nz,pgok                 ; reading: any page
        jr      .map
.phys:  ld      a,(T_CUR + 2)           ; a physical one: page = address >> 13
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,(T_CUR + 1)
        rlca
        rlca
        rlca
        and     7
        or      l
        ld      e,a
        ld      d,h
        call    pgok
.map:   ld      (T_PAGE),de
        ld      bc,MMU5_0_P
        out     (c),e
        inc     b
        out     (c),d
        ld      a,(T_CUR + 1)
        and     0x1F
        or      high AWIN
        ld      h,a
        ld      a,(T_CUR)
        ld      l,a
        ld      a,d
        cp      high PG_REG
        jr      nz,.ok
        ld      a,e
        cp      low PG_REG
        jr      z,secheck
.ok:    or      a
        ret
; Page DE: SRAM below the board's size, the register page, or the boot ROM
; (written only while ROMWE is set); C = 1 for a write. Otherwise ? address
pgok:   ld      a,d
        or      a
        ret     z                       ; pages 0x000-0x0FF: SRAM on every board
        dec     a
        jr      nz,.hi
        push    bc                      ; 0x100-0x1FF: SRAM on a 4 MB board
        ld      bc,SYSCFG_P
        in      a,(c)
        pop     bc
        and     SYSCFG_CHIPMB_M
        cp      4 << SYSCFG_CHIPMB_B
        ret     nc
        jp      e_addr
.hi:    dec     a
        dec     a
        jp      nz,e_addr               ; not 0x3xx
        ld      a,e
        cp      low PG_REG
        ret     z
        cp      low PG_ROM0
        jp      c,e_addr
        bit     0,c
        ret     z
        push    bc
        ld      bc,SYSCON_P
        in      a,(c)
        pop     bc
        and     SYSCON_ROMWE_M
        ret     nz
        jp      e_addr
; HL in the register page: carry if its read has side effects (HL kept)
secheck:
        push    hl
        ld      a,h
        sub     high AWIN
        ld      d,a
        ld      e,l
        ld      hl,setab
.l:     ld      a,(hl)
        inc     hl
        ld      b,(hl)
        inc     hl
        cp      e
        jr      nz,.n
        ld      a,b
        cp      d
        jr      z,.hit
.n:     inc     b
        jr      nz,.l
        pop     hl
        or      a
        ret
.hit:   pop     hl
        scf
        ret
; Register page offsets whose reads have side effects (spec 16, section 8.1)
setab:  dw      0x0020, 0x002D, 0x0035, 0x003D, 0x0045      ; TIME0, TMR0-3_COUNT0
        dw      0x0053, 0x005B, 0x005C, 0x005D, 0x0062      ; SERDATA, SDDATA, SERDROP, SDCOUNT0, KBDATA
        dw      0x100B                                      ; PALDAT
        dw      0x1010, 0x1020, 0x1030, 0x1040, 0x1050, 0x1060, 0x1070, 0x1080   ; SPR0-7PT0
        dw      0x10A4, 0x10C4, 0x10E4, 0x10F0, 0x10F4      ; L0-L2 BPL0PT0, BEAMPOS0, FRAMECOUNT0
        dw      0x110A, 0x1160, 0x11A0, 0x11E0, 0x1220, 0x1308   ; COPPC0, CHDESC0 0-3, SEQPT0
        dw      0xFFFF

; A = the byte at T_CUR; carry (and no read) for a side-effect register
rdb:    ld      c,0
        call    xlat
        ret     c
        ld      a,(hl)
        ret
; A = the byte at T_CUR, read even with side effects (E, explicit reads)
rdx:    ld      c,0
        call    xlat
        ld      a,(hl)
        or      a
        ret
; Write A at T_CUR
wrb:    push    af
        ld      c,1
        call    xlat
        pop     af
        ld      (hl),a
        ret
; ? address unless T_CUR can be written
chkw:   ld      c,1
        jp      xlat

; T_CUR = the CPU address HL
setcpu: ld      (T_CUR),hl
        xor     a
        ld      (T_CUR + 2),a
        ld      (T_CUR + 3),a
        ret
; The 4-byte address at HL plus 1 (a CPU address wraps at FFFF). A changed
adrinc: push    hl
        inc     (hl)
        jr      nz,.d
        inc     hl
        inc     (hl)
        jr      nz,.d
        inc     hl
        inc     hl
        bit     0,(hl)
        dec     hl
        jr      z,.d
        inc     (hl)
.d:     pop     hl
        ret
; ... and minus 1
adrdec: push    hl
        ld      a,(hl)
        dec     (hl)
        or      a
        jr      nz,.d
        inc     hl
        ld      a,(hl)
        dec     (hl)
        or      a
        jr      nz,.d
        inc     hl
        inc     hl
        bit     0,(hl)
        dec     hl
        jr      z,.d
        dec     (hl)
.d:     pop     hl
        ret
curinc: ld      hl,T_CUR
        jr      adrinc
; T_CUR = the 4 bytes at HL; (HL) = T_CUR
ldcur:  ld      de,T_CUR
        ld      bc,4
        ldir
        ret
stcur:  ex      de,hl
        ld      hl,T_CUR
        ld      bc,4
        ldir
        ret
; T_CNT minus 1: Z when it reaches 0. HL changed
cntdec: ld      hl,(T_CNT)
        ld      a,h
        or      l
        dec     hl
        ld      (T_CNT),hl
        jr      nz,cntz
        ld      hl,T_CNT + 2
        dec     (hl)
; Z if T_CNT is 0
cntz:   ld      hl,(T_CNT)
        ld      a,h
        or      l
        ld      hl,T_CNT + 2
        or      (hl)
        ret

; Print the address at T_CUR: 4 digits, or P and 6. A = the characters printed
pcur:   ld      a,(T_CUR + 3)
        rrca
        jr      nc,.cpu
        ld      a,'P'
        rst     08h
        ld      a,(T_CUR + 2)
        rst     28h
        db      6                       ; PUTHEX
        ld      hl,(T_CUR)
        rst     28h
        db      7                       ; PUTHEX16
        ld      a,7
        ret
.cpu:   ld      hl,(T_CUR)
        rst     28h
        db      7
        ld      a,4
        ret

; ================================================================ the commands
; ---- D[s] [addr [count]]: dump
c_dump: ld      hl,0x80
        ld      (T_CNT),hl
        xor     a
        ld      (T_CNT + 2),a
        call    pskip
        jr      z,.cont
        call    paddr
        ld      de,M_D
        call    tnum
        call    pskip
        jr      z,.go
        call    pcount
        call    pend
        jr      .go
.cont:  ld      a,(T_SZSET)             ; no address: carry on, as D last did
        or      a
        jr      nz,.go
.more:  ld      hl,0x80
        ld      (T_CNT),hl
        xor     a
        ld      (T_CNT + 2),a
        ld      a,(M_DSZ)
        ld      (T_SIZE),a
.go:    ld      a,(T_SIZE)
        ld      (M_DSZ),a
        dec     a
        ld      hl,T_CNT
        and     (hl)
        jp      nz,e_size
        ld      hl,M_D
        call    ldcur
.line:  call    cntz
        jr      z,.end
        call    dline
        jr      .line
.end:   ld      hl,M_D
        call    stcur
        ld      a,'D'
        ld      (M_LAST),a
        jp      mloop

; One line of D: up to 16 bytes from T_CUR (T_CUR and T_CNT move on)
dline:  call    pcur
        call    psp2
        ld      b,0                     ; B = the bytes read
.rd:    push    bc
        call    rdb
        pop     bc
        push    af
        ld      a,low T_DBUF
        add     a,b
        ld      l,a
        ld      h,high T_DBUF
        pop     af
        ld      d,0
        jr      nc,.r1
        inc     d                       ; not read: side effects
        xor     a
.r1:    ld      (hl),a
        ld      a,l
        add     a,16
        ld      l,a
        ld      (hl),d                  ; T_DSE
        inc     b
        push    bc
        call    curinc
        call    cntdec
        pop     bc
        jr      z,.items
        ld      a,b
        cp      16
        jr      c,.rd
.items: ld      a,b                     ; B = n
        ld      (T_I),a
        xor     a
        ld      (T_COL),a
        ld      c,0                     ; C = the item's first byte
.it:    ld      a,(T_SIZE)
        ld      e,a                     ; E = size
        ld      d,0                     ; any not read?
        ld      a,c
        add     a,low T_DSE
        ld      l,a
        ld      h,high T_DSE
        ld      b,e
.se:    ld      a,(hl)
        or      d
        ld      d,a
        inc     hl
        djnz    .se
        ld      a,c                     ; the item's last byte first
        add     a,e
        dec     a
        add     a,low T_DBUF
        ld      l,a
        ld      h,high T_DBUF
        ld      b,e
.hx:    ld      a,d
        or      a
        jr      z,.h1
        ld      a,'-'
        rst     08h
        rst     08h
        jr      .h2
.h1:    ld      a,(hl)
        rst     28h
        db      6
.h2:    dec     hl
        djnz    .hx
        ld      a,' '
        rst     08h
        ld      a,(T_COL)               ; 2 x size + 1 characters
        add     a,e
        add     a,e
        inc     a
        ld      (T_COL),a
        ld      a,c
        add     a,e
        ld      c,a
        cp      8
        jr      nz,.h3
        ld      a,' '                   ; the extra space after 8 bytes
        rst     08h
        ld      hl,T_COL
        inc     (hl)
.h3:    ld      a,(T_I)
        cp      c
        jr      z,.pad
        jr      nc,.it
.pad:   ld      a,(T_COL)               ; the characters start in column 49 + 1
        cp      49
        jr      nc,.asc
        ld      a,' '
        rst     08h
        ld      hl,T_COL
        inc     (hl)
        jr      .pad
.asc:   ld      a,' '
        rst     08h
        ld      a,(T_I)
        ld      b,a
        ld      hl,T_DBUF
.ch:    push    hl
        ld      a,l
        add     a,16
        ld      l,a
        ld      a,(hl)
        pop     hl
        or      a
        ld      a,'.'
        jr      nz,.c1
        ld      a,(hl)
        cp      32
        jr      c,.c0
        cp      127
        jr      c,.c1
.c0:    ld      a,'.'
.c1:    rst     08h
        inc     hl
        djnz    .ch
        jp      pnl

; ---- E[s] addr [value ...]: enter
c_enter:
        call    paddr
        ld      de,T_A1
        call    tnum
        call    pskip
        jr      z,.step
        call    pvals
        ld      hl,T_A1                 ; can every byte be written?
        call    ldcur
        ld      a,(T_VLEN)
        ld      b,a
.ck:    push    bc
        call    chkw
        call    curinc
        pop     bc
        djnz    .ck
        ld      hl,T_A1
        call    ldcur
        ld      a,(T_VLEN)
        ld      b,a
        ld      hl,T_VAL
.wr:    push    bc
        push    hl
        ld      a,(hl)
        call    wrb
        call    curinc
        pop     hl
        pop     bc
        inc     hl
        djnz    .wr
        jp      mloop
.step:  ld      hl,T_A1                 ; "addr: old ", then a new value
        call    ldcur
        call    pcur
        ld      a,':'
        rst     08h
        ld      a,' '
        rst     08h
        ld      hl,T_DBUF               ; the old value, read explicitly
        ld      a,(T_SIZE)
        ld      b,a
.old:   push    bc
        push    hl
        call    rdx
        pop     hl
        ld      (hl),a
        inc     hl
        push    hl
        call    curinc
        pop     hl
        pop     bc
        djnz    .old
        ld      a,(T_SIZE)
        ld      b,a
.ph:    dec     hl                      ; the high byte first
        ld      a,(hl)
        rst     28h
        db      6
        djnz    .ph
        ld      a,' '
        rst     08h
        ld      hl,EBUF
        ld      b,EBUFSZ
        ld      e,0
        call    gline
        jp      c,mloop                 ; Esc: the end
        ld      ix,EBUF
        call    pskip
        jr      z,.fwd                  ; Enter: keep it
        cp      '.'
        jp      z,mloop
        cp      '-'
        jr      z,.back
        call    pvals                   ; one value, of the size
        ld      a,(T_SIZE)
        ld      b,a
        ld      a,(T_VLEN)
        cp      b
        jr      nz,.bad
        ld      hl,T_A1
        call    ldcur
        ld      a,(T_SIZE)
        ld      b,a
        ld      hl,T_VAL
.w2:    push    bc
        push    hl
        ld      a,(hl)
        call    wrb
        call    curinc
        pop     hl
        pop     bc
        inc     hl
        djnz    .w2
.fwd:   ld      a,(T_SIZE)
        ld      b,a
.f1:    ld      hl,T_A1
        call    adrinc
        djnz    .f1
        jp      .step
.back:  ld      a,(T_SIZE)
        ld      b,a
.b1:    ld      hl,T_A1
        call    adrdec
        djnz    .b1
        jp      .step
.bad:   ld      hl,s_syntax
        rst     18h
        call    pnl
        jp      .step

; ---- F[s] addr count value: fill
c_fill: call    paddr
        ld      de,T_A1
        call    tnum
        call    pcount
        call    cntkeep
        call    pvals
        ld      hl,T_A1
        call    ldcur
        call    .cnt
.ck:    call    cntz
        jr      z,.wr
        call    chkw
        call    curinc
        call    cntdec
        jr      .ck
.wr:    ld      hl,T_A1
        call    ldcur
        call    .cnt
        ld      c,0                     ; C = the next value byte
.w:     call    cntz
        jp      z,mloop
        ld      a,c
        add     a,low T_VAL
        ld      l,a
        ld      h,high T_VAL
        ld      a,(hl)
        push    bc
        call    wrb
        call    curinc
        call    cntdec
        pop     bc
        inc     c
        ld      a,(T_VLEN)
        cp      c
        jr      nz,.w
        ld      c,0
        jr      .w
.cnt:   ld      hl,(T_CNT2)             ; T_CNT again from its copy
        ld      (T_CNT),hl
        ld      a,(T_CNT2 + 2)
        ld      (T_CNT + 2),a
        ret

; Keep T_CNT (the count of F, C, V), as the checks count it down
cntkeep:
        ld      hl,(T_CNT)
        ld      (T_CNT2),hl
        ld      a,(T_CNT + 2)
        ld      (T_CNT2 + 2),a
        ret

; ---- C addr count dest: copy
c_copy: ld      a,(T_SZSET)
        or      a
        jp      nz,e_size
        call    paddr
        ld      de,T_A1
        call    tnum
        call    pcount
        call    cntkeep
        call    paddr
        ld      de,T_A2
        call    tnum
        call    pend
        ld      hl,T_A1                 ; the source: readable, no side effects
        call    ldcur
.c1:    call    cntz
        jr      z,.c2
        ld      c,0
        call    xlat
        jp      c,e_addr
        call    curinc
        call    cntdec
        jr      .c1
.c2:    call    c_fill.cnt
        ld      hl,T_A2                 ; the destination: writable
        call    ldcur
.c3:    call    cntz
        jr      z,.dir
        call    chkw
        call    curinc
        call    cntdec
        jr      .c3
.dir:   call    c_fill.cnt
        call    cntz
        jp      z,mloop
        ; backwards when both are the same kind, dest > src and dest < src + count
        ld      a,(T_A1 + 3)
        ld      hl,T_A2 + 3
        cp      (hl)
        jr      nz,.fwd
        ld      hl,(T_A2)               ; dest - src (24 bits; a CPU address 16)
        ld      de,(T_A1)
        or      a
        sbc     hl,de
        ld      a,(T_A2 + 2)
        ld      b,a
        ld      a,(T_A1 + 2)
        ld      c,a
        ld      a,b
        sbc     a,c                     ; A:HL = dest - src
        jr      c,.fwd                  ; dest < src
        ld      b,a
        or      h
        or      l
        jp      z,mloop                 ; dest = src
        ld      a,(T_A1 + 3)
        or      a
        jr      nz,.p24
        ld      b,0                     ; CPU addresses: 16 bits
.p24:   ld      de,(T_CNT)              ; overlapping if dest - src < count
        or      a
        sbc     hl,de
        ld      a,(T_CNT + 2)
        ld      c,a
        ld      a,b
        sbc     a,c
        jr      nc,.fwd
        ld      b,0                     ; backwards: from the last byte
        call    .last
.bw:    call    .one
        call    cntdec
        jp      z,mloop
        ld      hl,T_A1
        call    adrdec
        ld      hl,T_A2
        call    adrdec
        jr      .bw
.fwd:   call    .one
        call    cntdec
        jp      z,mloop
        ld      hl,T_A1
        call    adrinc
        ld      hl,T_A2
        call    adrinc
        jr      .fwd
.one:   ld      hl,T_A1
        call    ldcur
        call    rdb
        push    af
        ld      hl,T_A2
        call    ldcur
        pop     af
        jp      wrb
; T_A1 and T_A2 plus count - 1
.last:  call    cntdec                  ; (T_CNT - 1 steps, then back)
        jr      z,.l2
        ld      hl,T_A1
        call    adrinc
        ld      hl,T_A2
        call    adrinc
        jr      .last
.l2:    jp      c_fill.cnt

; ---- V addr count addr2: compare
c_compare:
        ld      a,(T_SZSET)
        or      a
        jp      nz,e_size
        call    paddr
        ld      de,T_A1
        call    tnum
        call    pcount
        call    paddr
        ld      de,T_A2
        call    tnum
        call    pend
        ld      hl,0
        ld      (T_N),hl
        xor     a
        ld      (T_N + 2),a
.l:     call    cntz
        jr      z,.end
        ld      hl,T_A1
        call    ldcur
        call    rdb
        jr      c,.nx                   ; side effects: not compared
        ld      e,a
        push    de
        ld      hl,T_A2
        call    ldcur
        call    rdb
        pop     de
        jr      c,.nx
        cp      e
        jr      z,.nx
        ld      d,a
        ld      hl,(T_N)                ; one more difference (24 bits)
        inc     hl
        ld      (T_N),hl
        ld      a,h
        or      l
        jr      nz,.n1
        ld      hl,T_N + 2
        inc     (hl)
.n1:    ld      hl,(T_N)
        ld      a,(T_N + 2)
        or      h
        jr      nz,.nx
        ld      a,l
        cp      17
        jr      nc,.nx
        push    de
        ld      hl,T_A1                 ; "addr: xx  addr2: yy"
        call    ldcur
        call    pcur
        call    pcolon
        pop     de
        push    de
        ld      a,e
        rst     28h
        db      6
        call    psp2
        ld      hl,T_A2
        call    ldcur
        call    pcur
        call    pcolon
        pop     de
        ld      a,d
        rst     28h
        db      6
        call    pnl
.nx:    call    cntdec
        push    af
        ld      hl,T_A1
        call    adrinc
        ld      hl,T_A2
        call    adrinc
        pop     af
        jr      nz,.l
.end:   call    pmsg
        db      "Differences: ", 0
        ld      a,(T_N + 2)
        or      a
        jr      z,.e1
        rst     28h
        db      6
.e1:    ld      hl,(T_N)
        rst     28h
        db      7
        call    pnl
        jp      mloop

; ---- S[s] addr count value ...: search
c_search:
        call    paddr
        ld      de,M_SNEXT
        call    tnum
        call    pcount
        ld      hl,(T_CNT)
        ld      (M_SCNT),hl
        ld      a,(T_CNT + 2)
        ld      (M_SCNT + 2),a
        call    pvals
        ld      a,(T_VLEN)
        cp      33
        jp      nc,e_syntax
        ld      (M_SLEN),a
        ld      c,a
        ld      b,0
        ld      hl,T_VAL
        ld      de,M_SPAT
        ldir
.more:  xor     a                       ; up to 16 places
        ld      (T_N),a
        ld      (T_COL),a
.pos:   ld      hl,(M_SCNT)             ; room for the pattern?
        ld      a,(M_SCNT + 2)
        ld      e,a
        ld      a,(M_SLEN)
        ld      c,a
        ld      a,l
        sub     c
        ld      a,h
        sbc     a,0
        ld      a,e
        sbc     a,0
        jr      c,.done
        ld      hl,M_SNEXT
        call    ldcur
        ld      hl,M_SPAT
        ld      a,(M_SLEN)
        ld      b,a
.cmp:   push    bc
        push    hl
        call    rdb
        pop     hl
        pop     bc
        jr      c,.miss
        cp      (hl)
        jr      nz,.miss
        inc     hl
        push    bc
        push    hl
        call    curinc
        pop     hl
        pop     bc
        djnz    .cmp
        ld      hl,M_SNEXT              ; found
        call    ldcur
        call    pcur
        call    psp2
        ld      hl,T_COL
        inc     (hl)
        ld      a,(hl)
        cp      8
        jr      nz,.f1
        ld      (hl),0
        call    pnl
.f1:    ld      hl,T_N
        inc     (hl)
.miss:  ld      hl,M_SNEXT
        call    adrinc
        ld      hl,(M_SCNT)
        ld      a,h
        or      l
        dec     hl
        ld      (M_SCNT),hl
        jr      nz,.m1
        ld      hl,M_SCNT + 2
        dec     (hl)
.m1:    ld      a,(T_N)
        cp      16
        jr      c,.pos
        call    bol
        call    pmsg
        db      "Enter for more.", 13, 10, 0
        ld      a,'S'
        ld      (M_LAST),a
        jp      mloop
.done:  call    bol
        xor     a
        ld      (M_LAST),a
        ld      a,(T_N)
        or      a
        jp      nz,mloop
        call    pmsg
        db      "Not found.", 13, 10, 0
        jp      mloop

; ---- G [addr [break]]: go
c_go:   call    pskip
        jr      z,.noad
        call    pcpu
        ld      hl,(T_NUM)
        ld      (M_PC),hl
        call    pskip
        jr      z,.nobp
        call    pcpu                    ; the breakpoint
        call    pend
        ld      a,1
        jr      .bp
.noad:  ld      a,(M_RUN)               ; after "Program ended.": from ENTRY again
        or      a
        jr      nz,.nobp
        ld      hl,(M_PC)
        ld      de,EXIT
        or      a
        sbc     hl,de
        jr      nz,.nobp
        ld      hl,(M_ENTRY)
        ld      (M_PC),hl
.nobp:  xor     a
.bp:    ld      (T_FLAG),a
        ld      a,(M_RUN)               ; a new run: SP = FFFE holding EXIT
        or      a
        jr      nz,.frame
        ld      hl,(M_PC)
        ld      (M_ENTRY),hl
        ld      hl,0xFFFE
        ld      (M_SP),hl
        call    setcpu
        call    chkw
        call    curinc
        call    chkw
.frame: ld      hl,(M_SP)               ; the frame below SP must be writable
        ld      de,-10
        add     hl,de
        call    setcpu
        ld      b,10
.fc:    push    bc
        call    chkw
        call    curinc
        pop     bc
        djnz    .fc
        ld      a,(T_FLAG)              ; the breakpoint: RST 30h, read back
        or      a
        jr      z,.wr
        ld      hl,(T_NUM)
        ld      (M_BPADR),hl
        call    setcpu
        call    rdx
        ld      (M_BPOLD),a
        ld      a,0xF7
        call    wrb
        call    rdx
        cp      0xF7
        jr      z,.bpok
        ld      a,(M_BPOLD)
        call    wrb
        jp      e_addr
.bpok:  ld      a,1
        ld      (M_BPON),a
.wr:    ld      a,(M_RUN)
        or      a
        jr      nz,.w1
        ld      hl,0xFFFE               ; the program's return address: EXIT
        call    setcpu
        ld      a,low EXIT
        call    wrb
        call    curinc
        ld      a,high EXIT
        call    wrb
.w1:    ld      hl,(M_SP)               ; L, H, E, D, C, B, F, A, PC low, PC high
        ld      de,-10
        add     hl,de
        call    setcpu
        ld      hl,gframe
.w2:    ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      a,d
        or      e
        jr      z,.go
        ld      a,(de)
        push    hl
        call    wrb
        call    curinc
        pop     hl
        jr      .w2
.go:    ld      a,1
        ld      (M_RUN),a
        ld      hl,M_IM
        set     7,(hl)
        call    bol
        call    givescr
        call    wssum
        ld      (M_SUM),hl
        ld      a,(M_SPEED)
        ld      bc,CPUSPEED_P
        out     (c),a
        jp      g_final
gframe: dw      M_HL, M_HL + 1, M_DE, M_DE + 1, M_BC, M_BC + 1, M_AF, M_AF + 1, M_PC, M_PC + 1, 0

; ---- R [name [value]]: registers
c_regs: call    pskip
        jr      nz,.set
        call    showregs
        jp      mloop
.set:   ld      hl,0                    ; the name: letters and ', 0 after
        ld      (T_VAL),hl
        ld      (T_VAL + 2),hl
        ld      hl,T_VAL
        ld      b,4
.nm:    call    pchar
        cp      "'"
        jr      z,.nc
        cp      'A'
        jr      c,.ne
        cp      'Z' + 1
        jr      nc,.ne
.nc:    ld      (hl),a
        inc     hl
        inc     ix
        djnz    .nm
        jp      e_syntax
.ne:    ld      (hl),0
        call    pnumr
        call    pend
        ld      hl,rnames
.look:  ld      a,(hl)
        or      a
        jp      z,e_syntax
        push    hl
        ld      de,T_VAL
        ld      b,4
.cmp:   ld      a,(de)
        cp      (hl)
        jr      nz,.no
        inc     hl
        inc     de
        djnz    .cmp
        pop     af                      ; found: HL = its place, kind
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      a,(hl)                  ; 1 byte, 2 word, 3 IFF (0-1), 4 IM (0-2)
        ld      hl,(T_NUM + 2)          ; the value's top 16 bits must be 0
        ld      c,a
        ld      a,h
        or      l
        jp      nz,e_syntax
        ld      hl,(T_NUM)
        ld      a,c
        cp      2
        jr      z,.word
        ld      a,h                     ; a byte
        or      a
        jp      nz,e_syntax
        ld      a,c
        cp      3
        ld      a,l
        jr      c,.byte                 ; kind 1: any byte
        ld      b,1                     ; IFF up to 1, IM up to 2
        jr      z,.lim
        inc     b
.lim:   ld      a,b
        cp      l
        jp      c,e_syntax
        ld      a,c
        cp      4
        ld      a,l
        jr      nz,.byte
        or      0x40                    ; IM: set by R, so G runs it
.byte:  ld      (de),a
        jp      mloop
.word:  ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        jp      mloop
.no:    pop     hl
        ld      de,7
        add     hl,de
        jr      .look
; The names R takes: 4 characters (0 after), the place, the kind
rnames: db      "AF", 0, 0
        dw      M_AF
        db      2
        db      "BC", 0, 0
        dw      M_BC
        db      2
        db      "DE", 0, 0
        dw      M_DE
        db      2
        db      "HL", 0, 0
        dw      M_HL
        db      2
        db      "IX", 0, 0
        dw      M_IX
        db      2
        db      "IY", 0, 0
        dw      M_IY
        db      2
        db      "SP", 0, 0
        dw      M_SP
        db      2
        db      "PC", 0, 0
        dw      M_PC
        db      2
        db      "AF'", 0
        dw      M_AF2
        db      2
        db      "BC'", 0
        dw      M_BC2
        db      2
        db      "DE'", 0
        dw      M_DE2
        db      2
        db      "HL'", 0
        dw      M_HL2
        db      2
        db      "I", 0, 0, 0
        dw      M_I
        db      1
        db      "R", 0, 0, 0
        dw      M_R
        db      1
        db      "IFF", 0
        dw      M_IFF
        db      3
        db      "IM", 0, 0
        dw      M_IM
        db      4
        db      "A", 0, 0, 0
        dw      M_AF + 1
        db      1
        db      "F", 0, 0, 0
        dw      M_AF
        db      1
        db      "B", 0, 0, 0
        dw      M_BC + 1
        db      1
        db      "C", 0, 0, 0
        dw      M_BC
        db      1
        db      "D", 0, 0, 0
        dw      M_DE + 1
        db      1
        db      "E", 0, 0, 0
        dw      M_DE
        db      1
        db      "H", 0, 0, 0
        dw      M_HL + 1
        db      1
        db      "L", 0, 0, 0
        dw      M_HL
        db      1
        db      0

; The registers (spec 16, section 8.3):
; AF=0044 BC=0000 DE=0000 HL=800E IX=0000 IY=0000 SP=0000 PC=0040
; AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=12 IFF=0 IM=2?  Z P
showregs:
        ld      hl,rshow
        ld      de,M_AF
        ld      b,8
        call    .row
        call    pnl
        ld      b,4
        call    .row
        call    pmsg
        db      " I=", 0
        ld      a,(M_I)
        rst     28h
        db      6
        call    pmsg
        db      " R=", 0
        ld      a,(M_R)
        rst     28h
        db      6
        call    pmsg
        db      " IFF=", 0
        ld      a,(M_IFF)
        add     a,'0'
        rst     08h
        call    pmsg
        db      " IM=", 0
        ld      a,(M_IM)
        and     3
        add     a,'0'
        rst     08h
        ld      a,(M_IM)
        bit     7,a
        jr      z,.f
        ld      a,'?'
        rst     08h
.f:     ld      a,(M_AF)                ; the flags: S Z H P N C
        ld      c,a
        and     0xD7
        jr      z,.e
        ld      a,' '
        rst     08h
        ld      hl,flagn
        ld      b,8
.fl:    ld      a,(hl)
        inc     hl
        sla     c
        jr      nc,.fn
        or      a
        jr      z,.fn
        push    af
        ld      a,' '
        rst     08h
        pop     af
        rst     08h
.fn:    djnz    .fl
.e:     jp      pnl
; B registers, with a space between them
.row:   call    .one
        dec     b
        ret     z
        ld      a,' '
        rst     08h
        jr      .row
; One register: its name from HL (to a 0), "=", the word at DE
.one:   push    bc
        rst     18h
        ld      a,'='
        rst     08h
        ex      de,hl
        ld      c,(hl)
        inc     hl
        ld      b,(hl)
        inc     hl
        ex      de,hl
        push    hl
        ld      h,b
        ld      l,c
        rst     28h
        db      7
        pop     hl
        pop     bc
        ret
rshow:  db      "AF", 0, "BC", 0, "DE", 0, "HL", 0, "IX", 0, "IY", 0, "SP", 0, "PC", 0
        db      "AF'", 0, "BC'", 0, "DE'", 0, "HL'", 0
flagn:  db      'S', 'Z', 0, 'H', 0, 'P', 'N', 'C'

; ---- P port [value]: ports (spec 16, section 8.2)
c_port: ld      a,(T_SIZE)
        dec     a
        jp      nz,e_size
        call    pnumr
        ld      hl,(T_NUM + 2)
        ld      a,h
        or      l
        jp      nz,e_addr
        ld      hl,(T_NUM)
        ld      (T_A1),hl
        call    pskip
        jr      z,.rd
        call    pnumr
        call    pend
        ld      hl,(T_NUM + 1)          ; a byte
        ld      a,h
        or      l
        jp      nz,e_syntax
        call    .saved
        ld      a,(T_NUM)
        jr      nc,.mem
        ld      bc,(T_A1)
        out     (c),a
        jp      mloop
.mem:   ld      (hl),a
        jp      mloop
.rd:    call    .saved
        jr      nc,.m2
        ld      bc,(T_A1)
        in      a,(c)
        jr      .pr
.m2:    ld      a,(hl)
.pr:    push    af
        ld      hl,(T_A1)
        rst     28h
        db      7
        call    pcolon
        pop     af
        rst     28h
        db      6
        call    pnl
        jp      mloop
; NC and HL = the program's copy for the MMU registers and CPUSPEED, which
; the monitor has changed for itself; carry for every other port
.saved: ld      hl,(T_A1)
        ld      a,l
        or      a
        scf
        ret     nz
        ld      a,h
        cp      CPUSPEED
        jr      nz,.s1
        ld      hl,M_SPEED
        or      a
        ret
.s1:    sub     MMU0_0
        cp      32
        ccf
        ret     c
        ld      l,a
        ld      h,0
        ld      de,M_MMU
        add     hl,de
        or      a
        ret

; ---- H, ?: help
c_help: ld      hl,helptext
        rst     18h
        jp      mloop

; ================================================================ printing
; Print the string after the CALL (to its 0) and go on after it
pmsg:   pop     hl
        rst     18h
        jp      (hl)
pnl:    ld      a,13
        rst     08h
        ld      a,10
        rst     08h
        ret
psp2:   ld      a,' '
        rst     08h
        rst     08h
        ret
pcolon: ld      a,':'
        rst     08h
        ld      a,' '
        rst     08h
        ret
; A new line unless the cursor is at the start of one
bol:    rst     28h
        db      0x0B                    ; GETPOS
        ld      a,l
        or      a
        ret     z
        jr      pnl
