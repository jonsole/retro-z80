; The monitor's T command (shared spec, section 4.1; spec 16, section 8.9),
; in ROM page 2, included by boot.asm.
;
; T addr count tests count bytes from addr (a CPU address through the
; program's write pages, or a P address); T alone tests every SRAM page but
; the console's and the workspace's (0x0FE, 0x0FF). Four passes, each
; writing the whole range and then reading it all back: 55, AA, then each
; byte's physical address bits 7-0 XOR 15-8 XOR 23-16 (so two addresses
; one address line apart differ), then that inverted. It prints
;   Pass 1 2 3 4
;   Errors: 0000
; with a line "addr: wrote xx read yy" for each of the first 16 bad bytes.
; Esc (BREAK) stops it after the current 8 KB. The whole range is checked
; first: SRAM the monitor does not use, or ? address and nothing written.

c_test: ld      a,(T_SZSET)
        or      a
        jp      nz,e_size
        call    pskip
        jr      z,.all
        call    paddr
        ld      de,T_A1
        call    tnum
        call    pcount
        call    pend
        xor     a                       ; the monitor's pages: ? address
        jr      .go
.all:   ld      hl,0                    ; P000000, all the board's SRAM
        ld      (T_A1),hl
        ld      (T_CNT),hl
        ld      a,1
        ld      (T_A1 + 2),hl           ; (T_A1 + 3) = 0 for now
        ld      (T_A1 + 3),a
        call    pmsg
        db      "Testing P000000-P1FBFFF", 0
        ld      bc,SYSCFG_P
        in      a,(c)
        and     SYSCFG_CHIPMB_M
        cp      4 << SYSCFG_CHIPMB_B
        ld      a,0x20                  ; 2 MB
        jr      c,.mb
        call    pmsg
        db      ", P200000-P3FFFFF", 0
        ld      a,0x40                  ; 4 MB
.mb:    ld      (T_CNT + 2),a
        call    pnl
        ld      a,1                     ; the monitor's pages: skipped
.go:    ld      (T_FLAG),a
        call    cntkeep
        call    trew                    ; the check, writing nothing
.ck:    call    tnext
        jr      nz,.ck
        ld      hl,0
        ld      (T_N),hl
        xor     a
        ld      (T_N + 2),a
        ld      (T_VLEN),a              ; the pass, 0-3
        call    pmsg
        db      "Pass", 0
.pass:  ld      a,' '
        rst     08h
        ld      a,(T_VLEN)
        add     a,'1'
        rst     08h
        call    trew
.fill:  call    tnext
        jr      z,.vfy
        call    tfill
        call    tpoll
        jr      .fill
.vfy:   call    trew
.v:     call    tnext
        jr      z,.next
        call    tver
        call    tpoll
        jr      .v
.next:  ld      hl,T_VLEN
        inc     (hl)
        ld      a,(hl)
        cp      4
        jr      c,.pass
.end:   call    bol
        call    pmsg
        db      "Errors: ", 0
        ld      a,(T_N + 2)
        or      a
        jr      z,.e1
        rst     28h
        db      6                       ; PUTHEX
.e1:    ld      hl,(T_N)
        rst     28h
        db      7                       ; PUTHEX16
        call    pnl
        jp      mloop
.stop:  call    bol
        call    pmsg
        db      "Stopped.", 13, 10, 0
        jr      .end

; Esc stops the test; the watchdog is kicked (BC, DE, HL kept)
tpoll:  push    bc
        call    wdkick
        pop     bc
        rst     20h                     ; POLLC
        ret     z
        cp      27
        ret     nz
        jp      c_test.stop

; T_CUR and T_CNT back to the range's start
trew:   ld      hl,T_A1
        call    ldcur
        jp      c_fill.cnt

; The next piece of the range, up to the end of its 8 KB page: Z when there
; is none left. Otherwise HL = its first byte in the access window, BC = its
; length, T_A2 = its address, T_I = HL; T_CUR and T_CNT move on past it.
; ? address unless it is SRAM that may be written; the console's and the
; workspace's pages too, unless T_FLAG says skip them
tnext:  call    cntz
        ret     z
        ld      hl,(T_CUR)              ; to the end of the page: 0x2000 - offset
        ld      a,h
        and     0x1F
        ld      d,a
        ld      e,l
        ld      hl,0x2000
        or      a
        sbc     hl,de
        ld      a,(T_CNT + 2)           ; or less, if that is all that is left
        or      a
        jr      nz,.len
        ld      de,(T_CNT)
        push    hl
        sbc     hl,de                   ; (carry is clear)
        pop     hl
        jr      c,.len
        ex      de,hl
.len:   push    hl
        ld      c,1
        call    xlat                    ; HL in window 5
        pop     bc
        ld      de,(T_PAGE)             ; (xlat's DE is not the page in the register page)
        ld      a,d                     ; SRAM: pages 0x000-0x1FF
        cp      2
        jp      nc,e_addr
        or      a
        jr      nz,.ok
        ld      a,e
        cp      PG_CON                  ; 0x0FE, 0x0FF: the monitor's
        jr      c,.ok
        ld      a,(T_FLAG)
        or      a
        jp      z,e_addr
        call    .adv
        jr      tnext
.ok:    ld      (T_I),hl
        push    hl
        push    bc
        ld      hl,T_CUR
        ld      de,T_A2
        ld      bc,4
        ldir
        pop     bc
        pop     hl
        call    .adv
        or      1                       ; NZ
        ret
; T_CUR and T_CNT on by BC (BC, HL kept)
.adv:   push    hl
        ld      hl,(T_CUR)
        add     hl,bc
        ld      (T_CUR),hl
        jr      nc,.a1
        ld      a,(T_CUR + 3)           ; a CPU address wraps at FFFF
        rrca
        jr      nc,.a1
        ld      hl,T_CUR + 2
        inc     (hl)
.a1:    ld      hl,(T_CNT)
        or      a
        sbc     hl,bc
        ld      (T_CNT),hl
        jr      nc,.a2
        ld      hl,T_CNT + 2
        dec     (hl)
.a2:    pop     hl
        ret

; Write the pass's pattern to BC bytes from HL
tfill:  ld      a,(T_VLEN)
        cp      2
        jr      nc,.adr
        or      a
        ld      a,0x55
        jr      z,.c
        cpl
.c:     ld      (hl),a
        dec     bc
        ld      a,b
        or      c
        ret     z
        ld      d,h
        ld      e,l
        inc     de
        ldir
        ret
.adr:   call    tkey
.a:     ld      a,h
        and     0x1F
        xor     d
        xor     l
        ld      (hl),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.a
        ret

; Read BC bytes from HL back
tver:   ld      a,(T_VLEN)
        cp      2
        jr      nc,.adr
        or      a
        ld      a,0x55
        jr      z,.c0
        cpl
.c0:    ld      e,a
.c:     ld      a,e
        cpi
        jr      nz,.bad
        jp      pe,.c
        ret
.bad:   dec     hl
        call    terr
        inc     hl
        ld      a,b
        or      c
        jr      nz,.c
        ret
.adr:   call    tkey
.a:     ld      a,h
        and     0x1F
        xor     d
        xor     l
        cp      (hl)
        call    nz,terr
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.a
        ret

; D = the address pattern's part from the page (T_PAGE = P): with the
; window's offset bits 12-8 (H AND 1F) and bits 7-0 (L), the byte is
; L XOR (offset bits 12-8 + P bits 2-0 x 32) XOR P bits 9-3. Inverted in
; pass 4. BC, HL kept
tkey:   push    bc
        ld      de,(T_PAGE)
        ld      a,e
        and     7
        rrca
        rrca
        rrca
        ld      c,a
        ld      a,e
        rrca
        rrca
        rrca
        and     0x1F
        bit     0,d
        jr      z,.k
        or      0x20
.k:     xor     c
        ld      d,a
        ld      a,(T_VLEN)
        cp      3
        jr      nz,.k2
        ld      a,d
        cpl
        ld      d,a
.k2:    pop     bc
        ret

; A bad byte at HL, A the value written: count it, and print the first 16
; as "addr: wrote xx read yy". BC, DE, HL kept
terr:   push    bc
        push    de
        push    hl
        push    af
        ld      hl,(T_N)
        inc     hl
        ld      (T_N),hl
        ld      a,h
        or      l
        jr      nz,.c
        ld      hl,T_N + 2
        inc     (hl)
.c:     ld      a,(T_N + 2)
        or      a
        jr      nz,.q
        ld      hl,(T_N)
        ld      de,17
        sbc     hl,de                   ; (carry is clear)
        jr      nc,.q
        ld      hl,T_CUR                ; T_CUR kept in T_NUM
        ld      de,T_NUM
        ld      bc,4
        ldir
        ld      hl,T_A2                 ; the address: the piece's + the offset in it
        ld      de,T_CUR
        ld      c,4
        ldir
        pop     af
        pop     hl
        push    hl
        push    af
        ld      de,(T_I)
        or      a
        sbc     hl,de
        ld      de,(T_CUR)
        add     hl,de
        ld      (T_CUR),hl
        call    bol
        call    pcur
        call    pmsg
        db      ": wrote ", 0
        pop     af
        push    af
        rst     28h
        db      6
        call    pmsg
        db      " read ", 0
        pop     af
        pop     hl
        push    hl
        push    af
        ld      a,(hl)
        rst     28h
        db      6
        call    pnl
        ld      hl,T_NUM
        call    ldcur
.q:     pop     af
        pop     hl
        pop     de
        pop     bc
        ret
