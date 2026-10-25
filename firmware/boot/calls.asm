; The ROM calls (spec 16, section 7), in ROM page 0, included by boot.asm:
; the RST entries' routines, the RST 28h function table and GETLINE.
;
; A call keeps every register except its outputs and F. It reaches the
; console through ccall, which borrows a window for page 0x0FE for a few
; hundred T-states at most (a scroll: about 3,000) with interrupts off, and
; gives back the window's pages and the interrupt state exactly. Strings,
; buffers and the caller's stack are only touched outside the borrowed
; window, so they may be anywhere in 0x2000-0xFFFF.

CSTACK  equ     48                      ; stack a core routine may use below ccall's SP

; ---- ccall: run the core routine at HL (console.asm, keys.asm) with the
; console page in window 4 (or window 2 when the caller's stack is near
; window 4), IY at the console's state and interrupts off. D, E are its
; arguments and its results. A, B, C, H, L, F changed; IY kept.
ccall:  push    iy
        ld      a,i                     ; P/V = IFF2: were interrupts on?
        di
        push    af
        push    hl                      ; the core
        ld      hl,-CSTACK
        add     hl,sp
        ld      a,h
        and     0xE0
        cp      0x80
        jr      z,.w2
        ld      hl,0
        add     hl,sp
        ld      a,h
        and     0xE0
        cp      0x80
        ld      bc,MMU4_0_P
        jr      nz,.w
.w2:    ld      bc,MMU2_0_P
.w:     in      l,(c)                   ; the window's read page ...
        inc     b
        in      h,(c)
        push    hl
        ld      a,b
        add     a,MMU0W_0 - MMU0_1
        ld      b,a
        in      l,(c)                   ; ... and write page
        inc     b
        in      h,(c)
        push    hl
        ld      a,b
        sub     MMU0W_1 - MMU0_0
        ld      b,a
        push    bc
        ld      a,low PG_CON            ; the console page, read and write
        out     (c),a
        inc     b
        ld      a,high PG_CON
        out     (c),a
        ld      a,b                     ; MMUn_1 = 0x81 + 2n: the window's base is n x 0x2000
        sub     MMU0_1
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        ld      h,a
        ld      l,0xC0
        push    hl
        pop     iy
        ld      (iy+CS_BASE),a
        ld      hl,6
        add     hl,sp
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        call    jphl
        pop     bc                      ; the window
        pop     hl                      ; its write page
        ex      (sp),hl                 ; HL = its read page
        out     (c),l
        inc     b
        out     (c),h                   ; (the write page follows the read page)
        ld      a,b
        add     a,MMU0W_0 - MMU0_1
        ld      b,a
        pop     hl
        out     (c),l
        inc     b
        out     (c),h
        pop     hl
        pop     af
        pop     iy
        ret     po                      ; interrupts were off
        ei
        ret
jphl:   jp      (hl)

; ---- RST 08h PUTC, PUTRAW, SETPAIR: A in, nothing out
r_putc: push    hl
        ld      hl,k_putc
cA:     push    af
        push    bc
        push    de
        ld      e,a
        call    ccall
        pop     de
        pop     bc
        pop     af
        pop     hl
        ret
r_raw:  push    hl
        ld      hl,k_putraw
        jr      cA
r_spair: push   hl
        ld      hl,k_setpair
        jr      cA

; ---- RST 10h GETC: A = a key; waits, with the cursor blinking
r_getc: push    bc
        push    de
        push    hl
.l:     ld      hl,k_gstep
        call    ccall
        ld      a,e
        or      a
        jr      nz,.k
        call    wdkick
        jr      .l
.k:     pop     hl
        pop     de
        pop     bc
        ret

; ---- RST 20h POLLC: NZ and A = a key, or Z and A = 0
r_pollc: push   bc
        push    de
        push    hl
        ld      hl,k_poll
        call    ccall
        ld      a,e
        pop     hl
        pop     de
        pop     bc
        or      a
        ret

; ---- RST 18h PUTS: the string at HL, to its 0; HL = the byte after it
r_puts: push    af
.l:     ld      a,(hl)
        inc     hl
        or      a
        jr      z,.e
        rst     08h
        jr      .l
.e:     pop     af
        ret

; ---- RST 28h CALL: the function whose number is the byte after the RST
r_call: push    hl
        push    de
        push    af                      ; [AF][DE][HL][return]
        ld      hl,6
        add     hl,sp
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,(de)                  ; the number
        inc     de
        ld      (hl),d                  ; return after it
        dec     hl
        ld      (hl),e
        cp      NFUNC + 1
        jr      nc,.bad
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,ftab
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)                  ; DE = the function
        pop     af
        pop     hl                      ; HL = the caller's DE
        ex      de,hl
        ex      (sp),hl                 ; HL = the caller's HL; [function][return]
        ret
.bad:   pop     af
        pop     de
        pop     hl
        ld      a,1                     ; no such function
        scf
        ret

ftab:   dw      f_version, r_putc, r_getc, r_pollc, r_puts, f_getline, f_puthex, f_puthex16
        dw      f_putdec, f_cls, f_setpos, f_getpos, r_spair, r_raw, f_conmode, f_exit
        dw      f_break, f_reset

f_version:
        ld      a,(ROM_MAJOR << 4) | ROM_MINOR
        ld      b,NFUNC
        ld      hl,romid
        or      a
        ret

; PUTHEX: A as two hex digits (A kept)
f_puthex:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
        push    af
        call    .nib
        pop     af
        ret
.nib:   and     0x0F
        add     a,'0'
        cp      '9' + 1
        jr      c,.p
        add     a,'A' - '9' - 1
.p:     rst     08h
        ret

; PUTHEX16: HL as four hex digits
f_puthex16:
        push    af
        ld      a,h
        call    f_puthex
        ld      a,l
        call    f_puthex
        pop     af
        ret

; PUTDEC: HL as an unsigned decimal number
f_putdec:
        push    af
        push    bc
        push    de
        push    hl
        ld      c,0                     ; 1: a digit has been printed
        ld      de,10000
        call    .dig
        ld      de,1000
        call    .dig
        ld      de,100
        call    .dig
        ld      de,10
        call    .dig
        ld      a,l
        add     a,'0'
        rst     08h
        pop     hl
        pop     de
        pop     bc
        pop     af
        ret
.dig:   ld      a,'0' - 1
.sub:   inc     a
        or      a
        sbc     hl,de
        jr      nc,.sub
        add     hl,de
        cp      '0'
        jr      nz,.pr
        bit     0,c
        ret     z
.pr:    ld      c,1
        rst     08h
        ret

; CLS: a row of the map at a time, then the cursor home
f_cls:  push    af
        push    bc
        push    de
        push    hl
        ld      d,31
.row:   ld      hl,k_clrrow
        push    de
        call    ccall
        pop     de
        dec     d
        jp      p,.row
        ld      hl,k_home
        call    ccall
        pop     hl
        pop     de
        pop     bc
        pop     af
        ret

; SETPOS: H = row, L = column
f_setpos:
        push    af
        push    bc
        push    de
        push    hl
        ex      de,hl
        ld      hl,k_setpos
        call    ccall
        pop     hl
        pop     de
        pop     bc
        pop     af
        ret

; GETPOS: H = row, L = column
f_getpos:
        push    af
        push    bc
        push    de
        ld      hl,k_getpos
        call    ccall
        ex      de,hl
        pop     de
        pop     bc
        pop     af
        ret

; CONMODE: A = the new mode, or 0x80; A = the old mode
f_conmode:
        push    bc
        push    de
        push    hl
        ld      e,a
        ld      hl,k_conmode
        call    ccall
        ld      a,e
        pop     hl
        pop     de
        pop     bc
        ret

f_exit: inc     sp                      ; the return address is not needed
        inc     sp
        jp      EXIT
f_break: push   af
        ld      a,R_FBREAK
        jp      monent
f_reset: ld     bc,SYSRESET_P
        out     (c),a
        jr      $

; ---- GETLINE: HL = a buffer of B bytes (2-255). The line ends in 0; B = its
; length. Carry set and B = 0 if Esc was pressed. A kept
f_getline:
        push    af
        push    de
        push    bc
        ld      e,0
        call    gline
        ld      a,b                     ; (keeps the carry)
        pop     bc
        ld      b,a
        pop     de
        jr      c,.esc
        pop     af
        or      a
        ret
.esc:   pop     af
        scf
        ret

; The line editor for GETLINE and the monitor: HL = the buffer, B = its
; size, E = 1 if a Tab on an empty line ends it (the monitor's tape demo).
; Out: B = the length, E = what ended it: 13 Enter, 27 Esc (carry set), 9
; Tab. Echoes on the console; Backspace rubs out; Up brings back the last
; line (kept in the console page by Enter). C, D, E changed
gline:  ld      c,0                     ; the length so far
        dec     b                       ; room for the 0
        ld      d,e
.key:   rst     10h
        cp      13
        jr      z,.enter
        cp      27
        jr      z,.esc
        cp      8
        jr      z,.bs
        cp      139
        jr      z,.up
        cp      9
        jr      z,.tab
        cp      145                     ; F1: as Tab
        jr      nz,.chr
.tab:   bit     0,d
        jr      z,.key
        ld      e,a
        ld      a,c
        or      a
        jr      nz,.key
        ld      (hl),0
        ld      b,0
        or      a
        ret
.chr:   cp      32
        jr      c,.key
        cp      127
        jr      nc,.key
        ld      e,a
        ld      a,c
        cp      b
        jr      nc,.key                 ; full
        ld      a,e
        call    .put
        rst     08h
        jr      .key
.bs:    ld      a,c
        or      a
        jr      z,.key
        call    .rub
        jr      .key
.esc:   call    .nl
        ld      (hl),0
        ld      b,0
        ld      e,27
        scf
        ret
.enter: push    hl                      ; the end, and the line kept for Up
        ld      a,l
        add     a,c
        ld      l,a
        jr      nc,.e1
        inc     h
.e1:    ld      (hl),0
        pop     hl
        ld      a,c
        or      a
        call    nz,.keep
        call    .nl
        ld      b,c
        ld      e,13
        or      a
        ret
.up:    ld      a,c                     ; rub out the line, then the last one typed
        or      a
        jr      z,.u1
        call    .rub
        jr      .up
.u1:    push    de
        ld      d,0
.u2:    ld      a,c
        cp      b
        jr      nc,.u3
        push    hl
        push    bc
        ld      hl,k_hget
        call    ccall
        pop     bc
        pop     hl
        ld      a,e
        or      a
        jr      z,.u3
        call    .put
        rst     08h
        inc     d
        jr      .u2
.u3:    pop     de
        jp      .key
; A into the buffer at C, C + 1 (A kept)
.put:   push    hl
        push    af
        ld      a,l
        add     a,c
        ld      l,a
        jr      nc,.p1
        inc     h
.p1:    pop     af
        ld      (hl),a
        pop     hl
        inc     c
        ret
; Rub out the last character: C - 1, and BS, space, BS
.rub:   dec     c
        ld      a,8
        rst     08h
        ld      a,' '
        rst     08h
        ld      a,8
        rst     08h
        ret
.nl:    ld      a,13
        rst     08h
        ld      a,10
        rst     08h
        ret
; Keep the line (C bytes and its 0) for Up
.keep:  push    bc
        push    de
        push    hl
        ld      d,0
.k1:    ld      e,(hl)
        push    hl
        push    de
        ld      hl,k_hput
        call    ccall
        pop     de
        pop     hl
        inc     hl
        inc     d
        ld      a,e
        or      a
        jr      nz,.k1
        pop     hl
        pop     de
        pop     bc
        ret

; Kick the watchdog (harmless when it is off; A, B, C changed)
wdkick: ld      bc,WDKICK_P
        out     (c),a
        ret
