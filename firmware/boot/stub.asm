; The debug stub (ticket #29): the monitor in debug mode, serving the debug
; channel of debug.md (sections 4-7) to the bridge, tools/rz80_bridge.py.
; In ROM page 0, included by boot.asm (spec 16, section 8.8).
;
; Into debug mode: a HELLO frame at the monitor's prompt (mloop, through
; keys.asm's hwatch and the key KHELLO). Then:
;   - the stub answers commands one at a time in dloop, with the monitor's
;     own code for memory (xlat), registers (the M_ copies) and the map;
;   - the program's console output goes to the screen only (its CONMODE
;     with the serial bits off), and nothing is printed while it is stopped
;     (CONMODE 0): the screen is the program's (debug.md, section 4.3);
;   - CONTINUE and STEP leave through G (monitor.asm, c_go) and RETN; the
;     next stop comes back through ment2, which calls mkstop and, while
;     attached, dbg_stop: a STOP frame and dloop again;
;   - DETACH, or CONTINUE with DETACH, leaves debug mode.
; Errors in the monitor's code come back here: ? address while D_CATCH is 2
; (merr: refused, code 3), and the end of a CONSOLE line while it is 1
; (mloop). The stub's state is at 0x6EE0 (rom.inc); the frames are in page
; 0x0FC (link.asm).

T_REPLY equ     0x80                    ; debug.md, section 4.6
T_STOP  equ     0x81
ST_ENTRY equ    0                       ; STOP reasons (debug.md, section 6)
ST_PAUSE equ    1
ST_BUTTON equ   2
ST_BKPT equ     3
ST_WATCH equ    4
ST_STEP equ     5
ST_BREAK equ    6
ST_TRAP equ     7
ST_EXIT equ     8

; ---------------------------------------------------------------- start-up
; No session; every breakpoint and watchpoint off; the last stop a PAUSE at
; the monitor's PC (from minit, so start-up and a spoilt workspace)
dinit:  xor     a
        ld      (D_ATT),a
        ld      (D_SEQV),a
        ld      (D_CATCH),a
        ld      (D_GO),a
        ld      (D_STOPN),a
        ld      hl,D_STOP
        ld      b,15
.z:     ld      (hl),a
        inc     hl
        djnz    .z
        ld      a,ST_PAUSE
        ld      (D_STOP),a
        ld      a,(M_PC + 1)
        ld      (D_STOP + 4),a
        ld      a,(M_PC)
        ld      (D_STOP + 5),a
; Every breakpoint and watchpoint of the debug unit off (A, B, C, D changed)
dclear: xor     a
        ld      c,low DBGCTL_P          ; the debug unit's I/O page
        ld      b,DBGBP0 + DBGBP_CTL
        ld      d,4
.b:     out     (c),a
        ld      a,b
        add     a,DBGBP_SPAN
        ld      b,a
        xor     a
        dec     d
        jr      nz,.b
        ld      b,DBGWP0 + DBGWP_CTL
        out     (c),a
        ld      b,DBGWP1 + DBGWP_CTL
        out     (c),a
        ret

; ---------------------------------------------------------------- stops
; From ment2 (every entry into the monitor): the STOP payload for this stop
; into D_STOP. Z if attached (ment2 then goes to dbg_stop)
mkstop: ld      hl,D_STOP
        ld      b,15
        xor     a
.z:     ld      (hl),a
        inc     hl
        djnz    .z
        ld      a,(M_WHY)
        ld      c,ST_EXIT
        cp      R_EXIT
        jr      z,.r
        ld      c,ST_BREAK
        cp      R_BREAK
        jr      z,.r
        cp      R_FBREAK
        jr      z,.r
        ld      c,ST_TRAP
        cp      R_TRAP
        jr      z,.r
        ld      c,ST_PAUSE
        cp      R_NMI
        jr      nz,.r
        ld      a,(M_DBG)               ; the first in debug.md's order: WATCHPOINT,
        ld      b,a                     ; BREAKPOINT, STEP, BUTTON, PAUSE
        and     DBGSTAT_WP0_M | DBGSTAT_WP1_M
        jr      nz,.wp
        ld      a,b
        and     DBGSTAT_BP0_M | DBGSTAT_BP1_M | DBGSTAT_BP2_M | DBGSTAT_BP3_M
        jr      nz,.bp
        ld      c,ST_STEP
        bit     DBGSTAT_STEP_B,b
        jr      nz,.r
        ld      c,ST_BUTTON
        ld      a,(M_NMI)
        rrca
        jr      c,.r
        ld      c,ST_PAUSE
        jr      .r
.bp:    ld      c,ST_BKPT
        ld      d,0                     ; N: the lowest breakpoint that hit
.b1:    rrca
        jr      c,.b2
        inc     d
        jr      .b1
.b2:    ld      a,d
        ld      (D_STOP + 1),a
        jr      .r
.wp:    ld      c,ST_WATCH
        ld      a,(M_HITK)              ; the kept access (spec 18, section 6.3)
        and     DBGHITKIND_WP_M
        rrca
        rrca
        ld      (D_STOP + 1),a
        ld      a,(M_HITA + 1)
        ld      (D_STOP + 8),a          ; AADDR
        ld      a,(M_HITA)
        ld      (D_STOP + 9),a
        ld      a,(M_HITD)
        ld      (D_STOP + 13),a         ; ADATA
        ld      a,(M_HITK)
        and     DBGHITKIND_WRITE_M | DBGHITKIND_IO_M
        ld      (D_STOP + 14),a         ; AKIND
.r:     ld      a,c
        ld      (D_STOP),a              ; REASON
        ld      a,(M_PC + 1)
        ld      (D_STOP + 4),a          ; PC: the next instruction to run
        ld      a,(M_PC)
        ld      (D_STOP + 5),a
        ld      a,(D_ATT)
        cp      ATT_ON
        ret

; A stop while attached (from ment2, which took no screen and printed
; nothing): the STOP frame, then commands again
dbg_stop:
        ld      hl,CMAP + 0xC0 + CS_MODE ; the program's CONMODE kept; nothing printed meanwhile
        ld      a,(hl)
        ld      (D_PMODE),a
        ld      (hl),0
        call    stubmap
        call    dsstop
        jp      dloop

; Send the STOP frame for D_STOP, the stub's own count as its SEQ
dsstop: ld      hl,D_STOP
        ld      de,TXP
        ld      bc,15
        ldir
        ld      a,(D_STOPN)
        ld      e,a
        inc     a
        ld      (D_STOPN),a
        ld      a,T_STOP
        ld      bc,15
        jp      txframe

; From c_go, as G leaves: the CONMODE the stub chose for the program
dbg_gomode:
        ld      a,(D_GO)
        or      a
        ret     z
        xor     a
        ld      (D_GO),a
        ld      a,(D_GOM)
        ld      (CMAP + 0xC0 + CS_MODE),a
        ret

; ---------------------------------------------------------------- entering
; From mloop: KHELLO, so L F 0x10 came at the prompt. The rest of the frame;
; a good HELLO on the debug channel attaches (debug.md, section 4.4).
; Anything else goes back to the prompt
dbg_hello:
        ld      sp,MSTACK
        call    stubmap
        xor     a
        ld      (F_ESC),a
        ld      a,0x10
        call    rxrest
        cp      0xFF
        jp      z,mloop                 ; its bytes stopped
        ld      e,a
        ld      a,(F_CH)
        dec     a
        jp      nz,mloop                ; not the debug channel
        ld      a,(F_SEQ)
        ld      (D_SEQ),a
        ld      a,1
        ld      (D_SEQV),a
        ld      a,e
        or      a
        jp      z,d_hello
        ld      e,0                     ; C or F: answered, and the prompt again
        ld      bc,0
        call    dsend
        jp      mloop

; Debug mode on: the screen back to the program if the monitor had taken
; it, and the program's console on the screen only
dattach:
        ld      a,ATT_ON
        ld      (D_ATT),a
        call    givescr
        ld      hl,CMAP + 0xC0 + CS_MODE
        ld      a,(hl)
        ld      (D_OMODE),a
        and     0xF5                    ; bits 1 and 3: the link, out and in
        ld      (D_PMODE),a
        ld      (hl),0                  ; the stub prints nothing
        ret

; Debug mode off: no breakpoints or watchpoints, the console's link back
dleave: xor     a
        ld      (D_ATT),a
        ld      (D_SEQV),a
        call    dclear
        ld      a,(D_OMODE)
        and     0x0A
        ld      b,a
        ld      a,(D_PMODE)
        or      b
        ret                             ; A = the program's CONMODE with its link

; ---------------------------------------------------------------- the command loop
dloop:  ld      sp,MSTACK
        xor     a
        ld      (D_CATCH),a
        ld      (F_ESC),a
        ld      bc,DBGCTL_P             ; the debug unit not live in the stub (an NMI
        out     (c),a                   ; that came back here may have made it so)
        call    stubmap
        call    rxframe
        ld      e,a
        xor     a
        ld      bc,DBGCTL_P
        out     (c),a
        ld      a,(F_CH)
        dec     a
        jr      nz,dloop                ; not the debug channel: dropped
        ld      a,(F_TYPE)
        cp      0x10
        jr      c,dloop                 ; an upload frame: dropped
        ld      a,e
        or      a
        jr      z,.good
        ld      e,0                     ; C or F: answered, nothing done
        ld      bc,0
        call    dsend0
        jr      dloop
.good:  ld      a,(D_SEQV)              ; a repeated SEQ (debug.md, section 4.6)
        or      a
        jr      z,.new
        ld      a,(F_SEQ)
        ld      hl,D_SEQ
        cp      (hl)
        jr      nz,.new
        ld      a,(F_TYPE)              ; reads are done again
        cp      0x10                    ; HELLO
        jr      z,.new
        cp      0x11                    ; QUERY
        jr      z,.new
        cp      0x12                    ; READREGS
        jr      z,.new
        cp      0x14                    ; READMEM
        jr      z,.new
        cp      0x16                    ; READMMU
        jr      z,.new
        ld      a,(D_LCODE)             ; the rest: the first answer again, no data
        ld      e,a
        ld      a,(D_LST)
        ld      bc,0
        call    dsend0
        jr      dloop
.new:   ld      a,(F_SEQ)
        ld      (D_SEQ),a
        ld      a,1
        ld      (D_SEQV),a
        ld      a,(F_TYPE)
        sub     0x10
        cp      (dtab_end - dtab) / 2
        ld      e,1                     ; 1: unknown TYPE
        jp      nc,drefuse
        add     a,a
        ld      l,a
        ld      h,0
        ld      de,dtab
        add     hl,de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        jp      (hl)
dtab:   dw      d_hello, d_query, d_rregs, d_wregs, d_rmem, d_wmem, d_rmmu, d_setbp
        dw      d_clrbp, d_setwp, d_clrwp, d_cont, d_step, d_detach, d_console
dtab_end:

; ---- Replies (debug.md, section 4.6)
; The REPLY: A = STATUS, E = CODE, BC = the data's length (at TXD). dsend
; keeps STATUS and CODE for a repeated SEQ; dsend0 does not
dsend:  ld      (D_LST),a
        ld      d,a
        ld      a,e
        ld      (D_LCODE),a
        ld      a,d
dsend0: ld      hl,TXP
        ld      (hl),a
        inc     hl
        ld      (hl),e
        inc     bc
        inc     bc
        ld      a,(F_SEQ)
        ld      e,a
        ld      a,T_REPLY
        jp      txframe
; K with BC bytes of data, then the next command
dok:    ld      a,'K'
        ld      e,0
        call    dsend
; The next command: dloop while attached, otherwise the prompt
dnext:  ld      a,(D_ATT)
        cp      ATT_ON
        jp      z,dloop
        jp      mloop
dbad:   ld      e,2                     ; 2: a length or a field
        jr      drefuse
dbad3:  ld      e,3                     ; 3: the address or range
; Refused, code E
drefuse:
        ld      a,'R'
        ld      bc,0
        call    dsend
        jr      dnext
; ? address from the monitor's code (merr, with D_CATCH 2)
dbg_adderr:
        ld      sp,MSTACK
        xor     a
        ld      (D_CATCH),a
        jr      dbad3
; Z if the payload is A bytes long (A, HL changed)
dlen:   ld      hl,(F_PLEN)
        cp      l
        ret     nz
        ld      a,h
        or      a
        ret

; ---------------------------------------------------------------- the commands
; ---- HELLO: VERSION 1. The target description, then a STOP (the last)
d_hello:
        ld      a,1
        call    dlen
        jr      nz,dbad
        ld      a,(RXBUF)
        dec     a
        ld      e,8                     ; 8: a version the stub does not speak
        jr      nz,drefuse
        ld      a,(D_ATT)
        cp      ATT_ON
        call    nz,dattach
        ld      a,(M_PC + 1)            ; the STOP's PC as R shows it now
        ld      (D_STOP + 4),a
        ld      a,(M_PC)
        ld      (D_STOP + 5),a
        ld      hl,dtarget
        ld      de,TXD
        ld      bc,DTLEN
        push    bc
        ldir
        pop     bc
        ld      a,'K'
        ld      e,0
        call    dsend
        call    dsstop
        jp      dloop

; ---- QUERY: STATE 1 (stopped), then the last STOP's payload
d_query:
        ld      hl,TXD
        ld      (hl),1
        inc     hl
        ex      de,hl
        ld      hl,D_STOP
        ld      bc,15
        ldir
        ld      bc,16
        jp      dok

; ---- READREGS: the register block (debug.md, section 5.2)
d_rregs:
        ld      hl,TXD
        call    mkblk
        ld      bc,28
        jp      dok
; The register block to HL, from the monitor's copies (A, BC, DE, HL changed)
mkblk:  ld      de,M_AF                 ; AF ... HL', in the workspace's order, big-endian
        ld      b,12
.w:     ld      a,(de)
        inc     de
        ld      c,a
        ld      a,(de)
        inc     de
        ld      (hl),a
        inc     hl
        ld      (hl),c
        inc     hl
        djnz    .w
        ld      a,(M_I)
        ld      (hl),a
        inc     hl
        ld      a,(M_R)
        ld      (hl),a
        inc     hl
        ld      a,(M_IFF)               ; IFF1 and IFF2 (after an NMI IFF2 had IFF1)
        or      a
        jr      z,.f
        ld      a,3
.f:     ld      (hl),a
        inc     hl
        ld      a,(M_IM)                ; IM: not known once the program has run
        ld      c,a                     ; (bit 7), unless R or WRITEREGS set it (bit 6)
        and     0xC0
        cp      0x80
        ld      a,0xFF
        jr      z,.im
        ld      a,c
        and     3
.im:    ld      (hl),a
        ret

; ---- WRITEREGS: START, then bytes into the block
d_wregs:
        ld      hl,(F_PLEN)
        ld      a,h
        or      a
        jr      nz,.r6
        ld      a,l
        cp      2
        jp      c,dbad
        dec     a
        ld      b,a                     ; B = the bytes
        ld      a,(RXBUF)
        ld      c,a                     ; C = START
        add     a,b
        jr      c,.r6
        cp      29
        jr      nc,.r6
        push    bc
        ld      hl,D_BLK
        call    mkblk
        pop     bc
        ld      a,(D_BLK + 27)          ; IM as it is
        ld      (T_FLAG),a
        ld      hl,D_BLK
        ld      e,c
        ld      d,0
        add     hl,de
        ex      de,hl
        ld      hl,RXBUF + 1
        ld      c,b
        ld      b,0
        ldir
        ld      a,(D_BLK + 27)          ; IM changed: 0-2, and G sets it
        ld      hl,T_FLAG
        cp      (hl)
        jr      z,.im
        cp      3
        jp      nc,dbad
        or      0x40
        ld      (M_IM),a
.im:    ld      hl,D_BLK
        ld      de,M_AF
        ld      b,12
.w:     ld      a,(hl)
        inc     hl
        ld      c,a
        ld      a,(hl)
        inc     hl
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de
        djnz    .w
        ld      a,(hl)
        ld      (M_I),a
        inc     hl
        ld      a,(hl)
        ld      (M_R),a
        inc     hl
        ld      a,(hl)
        and     1
        ld      (M_IFF),a
        ld      bc,0
        jp      dok
.r6:    ld      e,6                     ; 6: outside the block
        jp      drefuse

; ---- READMEM: SPACE, FLAGS, ADDR, COUNT
d_rmem: ld      a,8
        call    dlen
        jp      nz,dbad
        ld      a,(RXBUF + 6)
        ld      b,a
        ld      a,(RXBUF + 7)
        ld      c,a                     ; COUNT, 1-2048
        call    dcount
        ld      c,0
        call    dmemck                  ; T_CUR, and every page can be read
        ld      hl,TXD
        ld      (T_SRC),hl
.c:     ld      hl,(T_CNT)
        ld      a,h
        or      l
        jr      z,.done
        ld      c,0
        call    xlat                    ; HL = the address in window 5
        call    droom                   ; BC = this piece
        push    bc
        ld      (T_NB),bc
        ld      de,(T_PAGE)             ; the register page: a byte at a time
        ld      a,d
        cp      high PG_REG
        jr      nz,.cp
        ld      a,e
        cp      low PG_REG
        jr      nz,.cp
.reg:   call    rdb                     ; carry: its read has side effects ...
        jr      nc,.r1
        ld      a,(RXBUF + 1)           ; ... read only with FLAGS bit 0
        rrca
        ld      a,0xFF
        jr      nc,.r1
        call    rdx
.r1:    ld      hl,(T_SRC)
        ld      (hl),a
        inc     hl
        ld      (T_SRC),hl
        call    curinc
        ld      bc,(T_NB)
        dec     bc
        ld      (T_NB),bc
        ld      a,b
        or      c
        jr      nz,.reg
        pop     bc                      ; (T_CUR has moved on already)
        jr      .nx
.cp:    ld      de,(T_SRC)
        ldir
        ld      (T_SRC),de
        pop     bc
        call    dcuradd
.nx:    ld      hl,(T_CNT)
        or      a
        sbc     hl,bc
        ld      (T_CNT),hl
        jr      .c
.done:  ld      hl,(T_SRC)
        ld      de,TXD
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
        jp      dok

; ---- WRITEMEM: SPACE, FLAGS, ADDR, then the bytes
d_wmem: ld      hl,(F_PLEN)
        ld      bc,-6
        add     hl,bc
        jp      nc,dbad                 ; under 6
        ld      b,h
        ld      c,l
        call    dcount                  ; 1-2048 bytes
        ld      c,1
        call    dmemck                  ; T_CUR, and every page can be written
        ld      hl,RXBUF + 6
        ld      (T_SRC),hl
.c:     ld      hl,(T_CNT)
        ld      a,h
        or      l
        ld      bc,0
        jp      z,dok
        ld      c,1
        call    xlat
        call    droom
        push    bc
        ex      de,hl
        ld      hl,(T_SRC)
        ldir                            ; low byte first: an MMU page commits on its high byte
        ld      (T_SRC),hl
        pop     bc
        call    dcuradd
        ld      hl,(T_CNT)
        or      a
        sbc     hl,bc
        ld      (T_CNT),hl
        jr      .c

; T_CNT = BC, which must be 1-2048 (else refused, 2)
dcount: ld      a,b
        or      c
        jp      z,dbad
        ld      hl,2048
        or      a
        sbc     hl,bc
        jp      c,dbad
        ld      (T_CNT),bc
        ret
; T_CUR = ADDR (RXBUF + 2, big-endian) in SPACE (RXBUF): 16 bits of a CPU
; address, 23 of a physical one. The range must lie in the space, every
; page of it must be one the monitor allows (C = 0 to read, 1 to write;
; xlat, ? address: refused, 3), and none the stub's own page 0x0FC
dmemck: ld      a,(RXBUF)               ; SPACE 0 or 1
        cp      2
        jp      nc,dbad
        ld      (T_CUR + 3),a
        ld      a,(RXBUF + 5)
        ld      (T_CUR),a
        ld      a,(RXBUF + 4)
        ld      (T_CUR + 1),a
        ld      a,(RXBUF + 3)
        and     0x7F
        ld      (T_CUR + 2),a
        ld      a,(T_CUR + 3)
        or      a
        jr      nz,.p
        ld      (T_CUR + 2),a           ; a CPU address: up to FFFF
        ld      hl,(T_CUR)
        ld      de,(T_CNT)
        add     hl,de
        jr      nc,.ok
        ld      a,h
        or      l
        jp      nz,dbad3
        jr      .ok
.p:     ld      hl,(T_CUR)              ; a physical one: up to P7FFFFF
        ld      de,(T_CNT)
        add     hl,de
        ld      a,(T_CUR + 2)
        adc     a,0
        cp      0x80
        jr      c,.ok
        jp      nz,dbad3
        ld      a,h
        or      l
        jp      nz,dbad3
.ok:    ld      a,c
        ld      (T_FLAG),a
        ld      a,2
        ld      (D_CATCH),a             ; ? address: refused, 3
        ld      hl,T_CUR                ; each page, from a copy
        ld      de,T_A1
        ld      bc,4
        ldir
        ld      hl,(T_CNT)
        ld      (T_CNT2),hl
.l:     ld      hl,(T_CNT)
        ld      a,h
        or      l
        jr      z,.end
        ld      a,(T_FLAG)
        ld      c,a
        call    xlat
        ld      hl,(T_PAGE)
        ld      de,PG_STUB
        or      a
        sbc     hl,de
        jp      z,dbad3
        call    droom
        call    dcuradd
        ld      hl,(T_CNT)
        or      a
        sbc     hl,bc
        ld      (T_CNT),hl
        jr      .l
.end:   ld      hl,T_A1
        ld      de,T_CUR
        ld      bc,4
        ldir
        ld      hl,(T_CNT2)
        ld      (T_CNT),hl
        ret
; BC = the bytes from T_CUR to the end of its page (or window), at most
; T_CNT. A, DE changed
droom:  push    hl
        ld      a,(T_CUR + 1)
        and     0x1F
        ld      d,a
        ld      a,(T_CUR)
        ld      e,a
        ld      hl,0x2000
        or      a
        sbc     hl,de                   ; HL = to the page's end
        ld      de,(T_CNT)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      c,.r
        ex      de,hl
.r:     ld      b,h
        ld      c,l
        pop     hl
        ret
; T_CUR plus BC (A, HL changed)
dcuradd:
        ld      hl,(T_CUR)
        add     hl,bc
        ld      (T_CUR),hl
        ret     nc
        ld      hl,T_CUR + 2
        inc     (hl)
        ret

; ---- READMMU: each window's read page and write page (the program's map)
d_rmmu: ld      hl,M_MMU
        ld      de,TXD
        ld      b,8
.l:     push    bc
        ld      c,(hl)
        inc     hl
        ld      a,(hl)
        inc     hl
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de
        push    hl
        ld      bc,14                   ; the write page, 16 bytes on
        add     hl,bc
        ld      c,(hl)
        inc     hl
        ld      a,(hl)
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de
        pop     hl
        pop     bc
        djnz    .l
        ld      bc,32
        jp      dok

; ---- SETBP: N, FLAGS (bit 0 PAGE), ADDR, PAGE
d_setbp:
        ld      a,8
        call    dlen
        jp      nz,dbad
        call    dbpn                    ; B = DBGBPn, C = the debug unit's page
        push    bc
        ld      a,b
        add     a,DBGBP_CTL
        ld      b,a
        xor     a
        out     (c),a                   ; off while it changes
        pop     bc
        ld      a,(RXBUF + 5)
        out     (c),a                   ; ADDR
        inc     b
        ld      a,(RXBUF + 4)
        out     (c),a
        inc     b
        ld      a,(RXBUF + 7)
        out     (c),a                   ; PAGE
        inc     b
        ld      a,(RXBUF + 6)
        and     3
        out     (c),a
        inc     b
        ld      a,(RXBUF + 1)
        and     1
        add     a,a
        or      DBGBP_CTL_EN_M          ; EN, and PAGEEN with PAGE
        out     (c),a
        ld      bc,0
        jp      dok
; ---- CLEARBP: N
d_clrbp:
        ld      a,1
        call    dlen
        jp      nz,dbad
        call    dbpn
        ld      a,b
        add     a,DBGBP_CTL
        ld      b,a
        xor     a
        out     (c),a
        ld      bc,0
        jp      dok
; B = DBGBPn for N (RXBUF), C = the page; N over 3 refused (4)
dbpn:   ld      a,(RXBUF)
        cp      4
        jr      nc,dbad4
        add     a,a
        add     a,a
        add     a,a
        add     a,DBGBP0
        ld      b,a
        ld      c,low DBGCTL_P
        ret
dbad4:  ld      e,4                     ; 4: no such number
        jp      drefuse

; ---- SETWP: N, KIND (bit 0 READ, 1 WRITE, 2 IO), ADDR, MASK
d_setwp:
        ld      a,10
        call    dlen
        jp      nz,dbad
        call    dwpn
        ld      a,(RXBUF + 1)
        and     3
        jp      z,dbad                  ; neither READ nor WRITE: 2
        ld      a,(RXBUF + 1)
        and     0xF8
        ld      e,5                     ; 5: a kind the unit does not have
        jp      nz,drefuse
        push    bc
        ld      a,b
        add     a,DBGWP_CTL
        ld      b,a
        xor     a
        out     (c),a
        pop     bc
        ld      a,(RXBUF + 5)
        out     (c),a                   ; ADDR
        inc     b
        ld      a,(RXBUF + 4)
        out     (c),a
        inc     b
        ld      a,(RXBUF + 9)
        out     (c),a                   ; MASK
        inc     b
        ld      a,(RXBUF + 8)
        out     (c),a
        inc     b
        ld      a,(RXBUF + 1)           ; CTL: EN, READ, WRITE, IO = 1 + KIND x 2
        add     a,a
        or      DBGWP_CTL_EN_M
        out     (c),a
        ld      bc,0
        jp      dok
; ---- CLEARWP: N
d_clrwp:
        ld      a,1
        call    dlen
        jp      nz,dbad
        call    dwpn
        ld      a,b
        add     a,DBGWP_CTL
        ld      b,a
        xor     a
        out     (c),a
        ld      bc,0
        jp      dok
; B = DBGWPn for N (RXBUF), C = the page; N over 1 refused (4)
dwpn:   ld      a,(RXBUF)
        cp      2
        jr      nc,dbad4
        add     a,a
        add     a,a
        add     a,a
        add     a,DBGWP0
        ld      b,a
        ld      c,low DBGCTL_P
        ret

; ---- CONTINUE: FLAGS bit 0 DETACH. The reply, then G
d_cont: call    dgo
        xor     a
        ld      (M_STEPF),a
        ld      a,(RXBUF)
        rrca
        jr      nc,dgoing.go
        call    dleave                  ; with DETACH: debug mode off first
dgoing:
        ld      (D_GOM),a
.go:    ld      a,1
        ld      (D_GO),a
        ld      a,2
        ld      (D_CATCH),a             ; (G's checks of the stack: refused, 3)
        jp      c_go.nobp
; ---- STEP: FLAGS bit 0 INTO (DBGCTL.STEPINT). The reply, then G with STEP
d_step: call    dgo
        ld      a,(RXBUF)
        and     1
        add     a,a
        or      DBGCTL_STEP_M
        ld      (M_STEPF),a
        jr      dgoing.go
; FLAGS, and a program that can go on (not ended: refused, 3); then K.
; D_GOM = the program's CONMODE
dgo:    ld      a,1
        call    dlen
        jp      nz,dbad
        ld      a,(D_STOP)
        cp      ST_EXIT
        jp      z,dbad3
        ld      a,(D_PMODE)
        ld      (D_GOM),a
        ld      a,'K'
        ld      e,0
        ld      bc,0
        jp      dsend

; ---- DETACH: debug mode off; the monitor's message, registers and prompt
d_detach:
        ld      a,'K'
        ld      e,0
        ld      bc,0
        call    dsend
        call    dleave
        ld      (CMAP + 0xC0 + CS_MODE),a
        call    takescr
        call    bol
        ld      a,(D_STOP + 4)          ; the message, as for the stop (ment2's texts)
        ld      h,a
        ld      a,(D_STOP + 5)
        ld      l,a
        ld      a,(D_STOP)
        cp      ST_BREAK                ; Break at the RST (M_SHOW, from ment2)
        jr      z,.sh
        ld      (M_SHOW),hl
.sh:    ld      hl,s_ended
        cp      ST_EXIT
        jp      z,ment2.m1
        cp      ST_WATCH
        jp      z,ment2.wp
        add     a,a
        ld      l,a
        ld      h,0
        ld      de,dmsgs
        add     hl,de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        jp      ment2.m2
dmsgs:  dw      s_loaded, s_nmiu, s_nmib, s_bkpt, 0, s_step, s_break, s_trap
s_loaded: db    "Loaded.  PC = ", 0

; ---- CONSOLE: a monitor command line, its output the reply (section 5.9)
d_console:
        ld      hl,(F_PLEN)             ; 1-80 bytes
        ld      a,h
        or      a
        jp      nz,dbad
        ld      a,l
        or      a
        jp      z,dbad
        cp      81
        jp      nc,dbad
        ld      c,a
        ld      b,0
        ld      hl,RXBUF
        ld      de,LBUF
        ldir
        xor     a
        ld      (de),a
        ld      ix,LBUF                 ; G N U L B X T refused (7), and Enter after N
        call    pskip
        jr      nz,.l
        ld      a,(M_LAST)
        cp      'N'
        jr      .r
.l:     ld      hl,dnot
        ld      b,dnot_end - dnot
.n:     cp      (hl)
        jr      z,.r
        inc     hl
        djnz    .n
        jr      .go
.r:     ld      e,7
        jp      z,drefuse
.go:    ld      a,(CMAP + 0xC0 + CS_ROW) ; output kept at TXD (CONMODE bit 4, console.asm)
        ld      (D_CROW),a
        ld      a,(CMAP + 0xC0 + CS_COL)
        ld      (D_CCOL),a
        xor     a
        ld      (CMAP + 0xC0 + CS_COL),a
        ld      hl,TXD
        ld      (CMAP + 0xC0 + CS_CAPP),hl
        ld      a,0x10
        ld      (CMAP + 0xC0 + CS_MODE),a
        ld      a,1
        ld      (D_CATCH),a
        jp      mloop.line
dnot:   db      "GNULBXT"
dnot_end:
; From mloop: the line has run. Its output is the reply
dbg_conend:
        xor     a
        ld      (D_CATCH),a
        ld      (CMAP + 0xC0 + CS_MODE),a
        ld      a,(D_CROW)
        ld      (CMAP + 0xC0 + CS_ROW),a
        ld      a,(D_CCOL)
        ld      (CMAP + 0xC0 + CS_COL),a
        call    stubmap
        ld      hl,(CMAP + 0xC0 + CS_CAPP)
        ld      de,TXD
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
        jp      dok

; ---- The target description (debug.md, section 5.2)
dtarget:
        db      1, "Z80 ", 16, 23, 4, 2, 0x0F, 8, 0x03
        db      high 2048, low 2048, 28, 16
        db      2, "AF", 0, 2, 4,  2, "BC", 2, 2, 0,  2, "DE", 4, 2, 0,  2, "HL", 6, 2, 0
        db      2, "IX", 8, 2, 0,  2, "IY", 10, 2, 0,  2, "SP", 12, 2, 2,  2, "PC", 14, 2, 1
        db      3, "AF'", 16, 2, 4,  3, "BC'", 18, 2, 0,  3, "DE'", 20, 2, 0,  3, "HL'", 22, 2, 0
        db      1, "I", 24, 1, 0,  1, "R", 25, 1, 0,  3, "IFF", 26, 1, 0,  2, "IM", 27, 1, 0
DTLEN   equ     $ - dtarget
