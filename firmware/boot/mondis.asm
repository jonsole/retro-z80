; The monitor's I command (shared spec, section 4.1; spec 16, section 8.4),
; in ROM page 2, included by boot.asm. The disassembler itself is
; disasm.asm.

; ---- I [addr [count]]: disassemble count instructions (16 by default)
; 8000  21 06 80     LD   HL,8006
; The address, two spaces, the bytes (3 characters each) padded to 4 bytes,
; a space, the instruction.
c_dis:  ld      a,(T_SZSET)
        or      a
        jp      nz,e_size
        call    pskip
        jr      z,.more                 ; no address: carry on
        call    paddr
        ld      de,M_INEXT
        call    tnum
        xor     a
        ld      (M_IRST),a
        call    pskip
        jr      z,.more
        call    pcount
        call    pend
        jr      .go
.more:  ld      hl,16                   ; (Enter after I comes here too)
        ld      (T_CNT),hl
        xor     a
        ld      (T_CNT + 2),a
.go:    ld      a,'I'
        ld      (M_LAST),a
.ins:   call    cntz
        jp      z,mloop
        ld      hl,M_INEXT
        call    ldcur
        call    pcur
        call    psp2
        ld      hl,(T_CUR)              ; the address for relative jumps: its low 16 bits
        ld      a,(M_IRST)
        ld      c,a
        call    dis                     ; A = the length (T_CUR has moved on)
        ld      b,a
        ld      hl,T_DSE                ; a byte not read (side effects): DB
        ld      c,b
.se:    ld      a,(hl)
        or      a
        jr      nz,.unrd
        inc     hl
        dec     c
        jr      nz,.se
        jr      .pr
.unrd:  ld      de,DISBUF               ; "DB   xx", or "DB   --"
        ld      a,t_db
        call    dtpl
        ld      a,(T_DSE)
        or      a
        jr      nz,.u1
        ld      a,(T_DBUF)
        call    dhex2
        jr      .u2
.u1:    ld      hl,s_un
        call    demits
.u2:    xor     a
        ld      (de),a
        ld      b,1
.pr:    ld      hl,T_DBUF               ; the bytes, -- for one not read
        ld      c,b
.by:    push    hl
        ld      a,l
        add     a,16
        ld      l,a
        ld      a,(hl)                  ; T_DSE
        pop     hl
        or      a
        ld      a,(hl)
        jr      z,.b1
        ld      a,'-'
        rst     08h
        rst     08h
        jr      .b2
.b1:    rst     28h
        db      6                       ; PUTHEX
.b2:    ld      a,' '
        rst     08h
        inc     hl
        dec     c
        jr      nz,.by
        ld      a,4                     ; padded to 4 bytes, then a space
        sub     b
        ld      c,a
        ld      a,' '
        rst     08h
.bp:    dec     c
        jp      m,.tx
        rst     08h
        rst     08h
        rst     08h
        jr      .bp
.tx:    ld      hl,DISBUF
        rst     18h
        call    pnl
        ld      hl,M_IRST               ; after RST 28h, the next byte is a function number
        ld      a,(hl)
        ld      (hl),0
        or      a
        jr      nz,.nx
        ld      a,b
        dec     a
        jr      nz,.nx
        ld      a,(T_DSE)
        or      a
        jr      nz,.nx
        ld      a,(T_DBUF)
        cp      0xEF
        jr      nz,.nx
        inc     (hl)
.nx:    ld      hl,M_INEXT              ; on by the length
        call    adrinc
        djnz    .nx
        call    cntdec
        jp      .ins
s_un:   db      "--", 0

; The disassembler's next byte (disasm.asm), from T_CUR, which moves on. The
; byte is kept in T_DBUF, and in T_DSE 1 if it was not read (side effects;
; then A = 0)
disget: push    bc
        push    de
        push    hl
        call    rdb
        ld      e,0
        jr      nc,.ok
        inc     e
        xor     a
.ok:    ld      d,a
        ld      a,(DV_LEN)
        add     a,low T_DBUF
        ld      l,a
        ld      h,high T_DBUF
        ld      (hl),d
        ld      a,l
        add     a,16
        ld      l,a
        ld      (hl),e                  ; T_DSE
        call    curinc
        ld      a,d
        pop     hl
        pop     de
        pop     bc
        ret
