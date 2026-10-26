; The link (ticket #29): CRC-32, frames from the PC and to it over the USB
; serial link (the shared spec "Monitor and upload protocol", sections 5.1
; and 6.2; debug.md, section 2), and the loader (monitor.md, section 6;
; spec 16, section 9), in ROM page 0, included by boot.asm.
;
; Frames are read whole into SRAM page 0x0FC, mapped into window 6 (RXBUF:
; the payload, 4 KB), and built there before they are sent (TXF). Their
; header and the loader's variables are at 0x6D00 in the workspace. The
; CRC table is in ROM page 2 (crctab.asm), in window 2. Bytes are taken
; from the link with INIR and sent with OTIR, as SERSTAT's counts allow.
;
;   rxframe  wait for a frame (SYNC LF) and read it whole
;   rxrest   the same once SYNC and TYPE are read (the prompt's HELLO)
;   txframe  send the transport frame at TXF (SYNC LD, CHANNEL 1)
;   txraw    send bytes as they are
;   loader   the loader: TARGET 0, programs (TARGET 1 and 2 are refused, 5)

S_TIMEOUT equ   3907                    ; 1 s in TIME's 256 us steps

; ---------------------------------------------------------------- CRC-32
; zlib's CRC (monitor.md, section 5.1), from the table in ROM page 2
crcinit:
        ld      hl,0xFFFF
        ld      (CRCV),hl
        ld      (CRCV + 2),hl
        ret

; CRCV over BC bytes at HL. A, BC, DE, HL and BC' changed. About 150
; T-states a byte
crcbuf: ld      a,b
        or      c
        ret     z
        push    ix
        push    bc
        exx
        pop     bc                      ; BC' = the count
        exx
        ex      de,hl                   ; DE = the data
        ld      bc,(CRCV)               ; C = bits 7-0, B = 15-8,
        ld      ix,(CRCV + 2)           ; IXL = 23-16, IXH = 31-24
.l:     ld      a,(de)
        inc     de
        xor     c
        ld      l,a                     ; the table's index
        ld      h,high crctab
        ld      a,(hl)
        xor     b
        ld      c,a
        inc     h
        ld      a,(hl)
        xor     ixl
        ld      b,a
        inc     h
        ld      a,(hl)
        xor     ixh
        ld      ixl,a
        inc     h
        ld      a,(hl)
        ld      ixh,a
        exx
        dec     bc
        ld      a,b
        or      c
        exx
        jr      nz,.l
        ld      (CRCV),bc
        ld      (CRCV + 2),ix
        pop     ix
        ret

; Z if the CRC (CRCV inverted) is the 4 bytes at DE, high byte first.
; A, B, DE, HL changed
crcchk: ld      hl,CRCV + 3
        ld      b,4
.l:     ld      a,(de)
        cpl
        cp      (hl)
        ret     nz
        dec     hl
        inc     de
        djnz    .l
        ret

; ---------------------------------------------------------------- bytes in
; Wait for bytes from the link: A = how many wait (1-255), NC. With F_TO,
; carry after 1 s with none; with F_ESC, carry and A = 27 for Esc on the
; keyboards (CONMODE must then leave the link's keys out). B, C changed
rxcnt:  push    hl
        call    ktime
        ld      (F_T),hl
.w:     ld      bc,SERSTAT1_P
        in      a,(c)
        or      a
        jr      nz,.got
        call    wdkick
        ld      a,(F_ESC)
        or      a
        jr      z,.t
        rst     20h                     ; POLLC: the keyboards
        cp      27
        jr      z,.esc
.t:     ld      a,(F_TO)
        or      a
        jr      z,.w
        call    ktime
        ld      bc,(F_T)
        or      a
        sbc     hl,bc
        ld      bc,S_TIMEOUT
        or      a
        sbc     hl,bc
        jr      c,.w
        xor     a
.esc:   scf
.got:   pop     hl
        ret

; A = a byte from the link (NC), or carry as rxcnt. B, C changed
rxb:    call    rxcnt
        ret     c
        in      a,(SERDATA_PORT)
        or      a
        ret

; DE bytes from the link to HL (F_TO: carry if they stop for 1 s).
; A, BC, DE, HL changed
rxn:    ld      a,d
        or      e
        ret     z
        call    rxcnt
        ret     c
        ld      b,a                     ; B = the smaller of the count and DE
        ld      a,d
        or      a
        jr      nz,.n
        ld      a,e
        cp      b
        jr      nc,.n
        ld      b,e
.n:     ld      a,e
        sub     b
        ld      e,a
        jr      nc,.n2
        dec     d
.n2:    ld      c,SERDATA_PORT
        inir
        jr      rxn

; ---------------------------------------------------------------- frames in
; Wait for a frame from the PC and read it whole: the header at F_HDR, the
; payload at RXBUF, LENGTH in F_PLEN. A = 0 a good frame; 'C' a CRC error;
; 'F' a frame error: NLENGTH does not match, LENGTH is over 4,096 (the rest
; is not read), or bytes 5-7 of a transport frame (TYPE 0x10 up) are not 0.
; Carry: Esc (F_ESC). A frame whose bytes stop for 1 s is dropped.
rxframe:
        xor     a
        ld      (F_TO),a
        call    rxb                     ; SYNC: L ...
        ret     c
.l:     cp      'L'
        jr      nz,rxframe
        call    rxb
        ret     c
        cp      'F'                     ; ... F
        jr      nz,.l
        ld      a,1
        ld      (F_TO),a
        call    rxb
        jr      c,rxframe
        call    rxrest
        cp      0xFF
        jr      z,rxframe               ; dropped
        or      a
        ret
; The rest of a frame whose SYNC and TYPE (A) are read. A as rxframe, or
; 0xFF if the frame was dropped (its bytes stopped for 1 s). NC
rxrest: ld      (F_HDR),a
        ld      a,1
        ld      (F_TO),a
        ld      hl,F_HDR + 1
        ld      de,9
        call    rxn
        jr      c,.drop
        ld      a,(F_LEN)
        ld      d,a
        ld      a,(F_LEN + 1)
        ld      e,a                     ; DE = LENGTH
        ld      a,(F_NLEN)
        cpl
        cp      d
        jr      nz,.ferr
        ld      a,(F_NLEN + 1)
        cpl
        cp      e
        jr      nz,.ferr
        ld      hl,4096
        or      a
        sbc     hl,de
        jr      c,.ferr
        ld      (F_PLEN),de
        ld      hl,RXBUF
        call    rxn
        jr      c,.drop
        ld      hl,F_CRC
        ld      de,4
        call    rxn
        jr      c,.drop
        call    crcinit
        ld      hl,F_HDR
        ld      bc,10
        call    crcbuf
        ld      hl,RXBUF
        ld      bc,(F_PLEN)
        call    crcbuf
        ld      de,F_CRC
        call    crcchk
        ld      a,'C'
        jr      nz,.ret
        ld      a,(F_TYPE)              ; a transport frame: bytes 5-7 are 0
        cp      0x10
        jr      c,.ok
        ld      hl,(F_HDR + 3)
        ld      a,h
        or      l
        ld      hl,F_HDR + 5
        or      (hl)
        jr      nz,.ferr
.ok:    xor     a
        ret
.ferr:  ld      a,'F'
.ret:   or      a
        ret
.drop:  ld      a,0xFF
        or      a
        ret

; ---------------------------------------------------------------- frames out
; Send BC bytes at HL as they are, waiting for room in the transmit FIFO.
; With no room for about 0.1 s nobody reads: the rest goes without waiting
; (TXDROP). A, BC, DE, HL changed
txraw0: xor     a
        ld      (F_NOPC),a
txraw:  ld      d,b
        ld      e,c
.l:     ld      a,d
        or      e
        ret     z
        call    txroom                  ; A = room, 1-255
        ld      b,a                     ; B = the smaller of the room and DE
        ld      a,d
        or      a
        jr      nz,.n
        ld      a,e
        cp      b
        jr      nc,.n
        ld      b,e
.n:     ld      a,e
        sub     b
        ld      e,a
        jr      nc,.n2
        dec     d
.n2:    ld      c,SERDATA_PORT
        otir
        jr      .l
; A = the room in the transmit FIFO (B, C changed)
txroom: ld      a,(F_NOPC)
        or      a
        ld      a,255
        ret     nz
        push    hl
        ld      hl,0
.w:     ld      bc,SERSTAT0_P           ; TXSPACE
        in      a,(c)
        or      a
        jr      nz,.r
        dec     hl                      ; 65,536 tries: about 0.1 s
        ld      a,h
        or      l
        jr      nz,.w
        ld      a,1
        ld      (F_NOPC),a
        ld      a,255
.r:     pop     hl
        ret

; Send the transport frame at TXF (debug.md, section 2.1): A = TYPE, E =
; SEQ, BC = LENGTH (the payload at TXP); SYNC LD, CHANNEL 1. A, BC, DE, HL
; and BC' changed
txframe:
        ld      hl,TXF
        ld      (hl),'L'
        inc     hl
        ld      (hl),'D'
        inc     hl
        ld      (hl),a                  ; TYPE
        inc     hl
        ld      (hl),e                  ; SEQ
        inc     hl
        ld      (hl),1                  ; CHANNEL: DEBUG
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),b                  ; LENGTH
        inc     hl
        ld      (hl),c
        inc     hl
        ld      a,b
        cpl
        ld      (hl),a                  ; NLENGTH
        inc     hl
        ld      a,c
        cpl
        ld      (hl),a
        push    bc
        call    crcinit
        pop     bc
        push    bc
        ld      hl,10
        add     hl,bc
        ld      b,h
        ld      c,l
        ld      hl,TXF + 2
        call    crcbuf                  ; TYPE to the payload's end
        pop     bc
        ld      hl,TXP
        add     hl,bc
        ld      de,CRCV + 3             ; the CRC, inverted, high byte first
        ld      b,4
.c:     ld      a,(de)
        cpl
        ld      (hl),a
        inc     hl
        dec     de
        djnz    .c
        ld      de,TXF
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
        ex      de,hl
        jp      txraw0

; Window 6: the frame buffers, SRAM page 0x0FC (A, B, C changed)
stubmap:
        ld      bc,MMU6_0_P
        ld      a,low PG_STUB
        out     (c),a
        inc     b
        ld      a,high PG_STUB
        out     (c),a                   ; read and write page
        ret

; ---------------------------------------------------------------- physical memory
; Map the page of the physical address T_P into window 5: HL = its address
; there, BC = the bytes to the end of the page. A, DE changed
pmap:   ld      a,(T_P + 2)             ; page = T_P >> 13
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,(T_P + 1)
        rlca
        rlca
        rlca
        and     7
        or      l
        ld      e,a
        ld      d,h
        ld      bc,MMU5_0_P
        out     (c),e
        inc     b
        out     (c),d
        ld      a,(T_P + 1)
        and     0x1F
        or      high AWIN
        ld      d,a
        ld      a,(T_P)
        ld      e,a                     ; DE = the address in window 5
        ld      hl,AWIN + 0x2000
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
        ex      de,hl
        ret
; T_P plus BC (HL changed)
padd:   ld      hl,(T_P)
        add     hl,bc
        ld      (T_P),hl
        ret     nc
        ld      hl,T_P + 2
        inc     (hl)
        ret
; BC = the smaller of BC and T_NB (24 bits); T_NB less it. A, DE, HL changed
pmin:   ld      a,(T_NB + 2)
        or      a
        jr      nz,.sub
        ld      hl,(T_NB)
        or      a
        sbc     hl,bc
        jr      nc,.sub
        ld      bc,(T_NB)
.sub:   ld      hl,(T_NB)
        or      a
        sbc     hl,bc
        ld      (T_NB),hl
        ret     nc
        ld      hl,T_NB + 2
        dec     (hl)
        ret

; ---------------------------------------------------------------- the loader
; monitor.md, section 6; spec 16, section 9. TARGET 0 (a program, LOAD a
; CPU address, or a physical one with PHYS); TARGET 1 and 2 are refused
; (code 5) until their tickets. From U, or from start-up after UPLOAD
c_upload:
        call    pend
loader: ld      sp,MSTACK
        ld      a,MON_ON
        ld      (M_MON),a               ; an NMI goes straight back
        call    stubmap
        ld      hl,CMAP + 0xC0 + CS_MODE
        ld      a,(hl)
        ld      (L_MODE),a
        ld      (hl),0x05               ; the screen and the keyboards: the link is the loader's
        ld      hl,col_yellow
        call    setbg
        call    bol
        call    pmsg
        db      "Waiting for upload.  BREAK for the monitor.", 13, 10, 0
        xor     a
        ld      (L_OK),a
        ld      (L_SEQV),a
lready: ld      hl,s_ready              ; the ready line (monitor.md, section 6.1)
        ld      bc,s_ready_end - s_ready
        call    txraw0
lwait:  ld      sp,MSTACK
        ld      a,1
        ld      (F_ESC),a
        call    rxframe
        push    af
        xor     a
        ld      (F_ESC),a
        pop     af
        jp      c,lesc
        or      a
        jr      z,.good
        ld      e,0                     ; C or F: nothing kept
        call    lreply
        jr      lwait
.good:  ld      a,(F_TYPE)
        cp      5
        jr      c,.t
        ld      a,'F'                   ; an unknown TYPE
        ld      e,0
        call    lreply
        jr      lwait
.t:     or      a
        jr      nz,.np
        ld      a,'K'                   ; PING: K with the version, and the ready line again
        ld      e,1
        call    lreply
        jr      lready
.np:    ld      a,(L_SEQV)              ; the frame taken last, again: K, not used twice
        or      a
        jr      z,.new
        ld      a,(F_SEQ)
        ld      hl,L_SEQ
        cp      (hl)
        jr      nz,.new
        call    lk
        jr      lwait
.new:   ld      a,(F_TYPE)
        dec     a
        jp      z,lhead
        dec     a
        jp      z,ldata
        dec     a
        jp      z,lend
        xor     a                       ; ABORT: the upload dropped
        ld      (L_OK),a
; The frame is taken: K
ltaken: ld      a,(F_SEQ)
        ld      (L_SEQ),a
        ld      a,1
        ld      (L_SEQV),a
        call    lk
        jr      lwait
lk:     ld      a,'K'
        ld      e,0
; The reply "LR", STATUS (A), SEQ, CODE (E) (monitor.md, section 6.3)
lreply: ld      hl,TXF
        ld      (hl),'L'
        inc     hl
        ld      (hl),'R'
        inc     hl
        ld      (hl),a
        inc     hl
        ld      a,(F_SEQ)
        ld      (hl),a
        inc     hl
        ld      (hl),e
        ld      hl,TXF
        ld      bc,5
        jp      txraw0
; Refused, code E: nothing kept, the loader waits on
lrefuse:
        ld      a,'R'
        call    lreply
        jp      lwait
; Esc on the keyboards: back to the monitor
lesc:   call    lback
        call    pmsg
        db      "Stopped.", 13, 10, 0
        jp      mloop
lback:  ld      a,(L_MODE)
        ld      (CMAP + 0xC0 + CS_MODE),a
        ld      hl,col_black
        jp      setbg

; HEADER: the image header (monitor.md, section 5; spec 16, section 9)
lhead:  xor     a
        ld      (L_OK),a
        ld      e,2                     ; 2: a bad header
        ld      hl,(F_PLEN)
        ld      a,h
        or      a
        jp      nz,lrefuse
        ld      a,l
        cp      32
        jp      nz,lrefuse
        ld      hl,RXBUF                ; MAGIC
        ld      de,s_rimg
        call    cmp4
        jp      nz,lrefuse
        ld      hl,RXBUF + 4            ; MACHINE
        ld      de,s_z80
        call    cmp4
        ld      e,1
        jp      nz,lrefuse
        ld      e,2
        ld      a,(RXBUF + 8)           ; VERSION 1
        dec     a
        jp      nz,lrefuse
        ld      a,(RXBUF + 10)          ; FLAGS: bit 0 PHYS, the rest 0
        or      a
        jp      nz,lrefuse
        ld      a,(RXBUF + 11)
        and     0xFE
        jp      nz,lrefuse
        call    crcinit                 ; HCRC
        ld      hl,RXBUF
        ld      bc,28
        call    crcbuf
        ld      de,RXBUF + 28
        call    crcchk
        ld      e,2
        jp      nz,lrefuse
        ld      a,(RXBUF + 9)           ; TARGET 0 only, for now
        or      a
        ld      e,5
        jp      nz,lrefuse
        ld      hl,RXBUF + 15
        ld      de,L_LOAD
        call    be4
        ld      hl,RXBUF + 19
        ld      de,L_ENTRY
        call    be4
        ld      hl,RXBUF + 23
        ld      de,L_SIZE
        call    be4
        ld      hl,RXBUF + 24
        ld      de,L_ICRC
        ld      bc,4
        ldir
        ld      e,3                     ; 3: outside what this machine allows
        ld      hl,(L_ENTRY + 2)        ; ENTRY 2000-FFFF
        ld      a,h
        or      l
        jp      nz,lrefuse
        ld      a,(L_ENTRY + 1)
        cp      0x20
        jp      c,lrefuse
        ld      hl,(L_SIZE)             ; SIZE 1 or more ...
        ld      a,h
        or      l
        ld      hl,L_SIZE + 2
        or      (hl)
        jp      z,lrefuse
        ld      e,4
        ld      a,(L_SIZE + 3)          ; ... and below 16 MB
        or      a
        jp      nz,lrefuse
        ld      e,3
        ld      a,(L_LOAD + 3)
        or      a
        jp      nz,lrefuse
        ld      hl,(L_LOAD)             ; T_P = LOAD + SIZE, the end
        ld      de,(L_SIZE)
        add     hl,de
        ld      (T_P),hl
        ld      a,(L_LOAD + 2)
        ld      b,a
        ld      a,(L_SIZE + 2)
        adc     a,b
        ld      (T_P + 2),a
        jp      c,lrefuse
        ld      a,(RXBUF + 11)
        rrca
        jr      c,.phys
        ld      e,4                     ; a CPU address: SIZE up to 57,342 ...
        ld      a,(L_SIZE + 2)
        or      a
        jp      nz,lrefuse
        ld      hl,(L_SIZE)
        ld      bc,57343
        or      a
        sbc     hl,bc
        jp      nc,lrefuse
        ld      e,3                     ; ... LOAD 2000 up, the end at FFFE at most
        ld      a,(L_LOAD + 2)
        or      a
        jp      nz,lrefuse
        ld      a,(L_LOAD + 1)
        cp      0x20
        jp      c,lrefuse
        ld      a,(T_P + 2)
        or      a
        jp      nz,lrefuse
        ld      hl,(T_P)
        ld      bc,0xFFFF
        or      a
        sbc     hl,bc
        jp      nc,lrefuse
        jr      .ok
.phys:  ld      bc,SYSCFG_P             ; physical: the end within the board's SRAM ...
        in      a,(c)
        and     SYSCFG_CHIPMB_M
        add     a,a
        add     a,a                     ; the size's bits 23-16 (MB x 16)
        ld      b,a
        ld      a,(T_P + 2)
        cp      b
        jr      c,.p1
        jp      nz,lrefuse
        ld      hl,(T_P)
        ld      a,h
        or      l
        jp      nz,lrefuse
.p1:    ld      a,(L_LOAD + 2)          ; ... and clear of the ROM's pages 0F8-0FF
        cp      0x20
        jr      nc,.ok
        ld      a,(T_P + 2)
        cp      0x1F
        jr      c,.ok
        jp      nz,lrefuse
        ld      hl,(T_P)
        ld      a,h
        or      l
        jp      nz,lrefuse
.ok:    ld      a,1
        ld      (L_OK),a
        ld      hl,0
        ld      (L_GOT),hl
        ld      (L_GOT + 2),hl
        call    pmsg                    ; on the screen only (CONMODE 5 now)
        db      "Program: load P", 0
        ld      a,(L_LOAD + 2)
        rst     28h
        db      6                       ; PUTHEX
        ld      hl,(L_LOAD)
        rst     28h
        db      7                       ; PUTHEX16
        call    pmsg
        db      ", entry ", 0
        ld      hl,(L_ENTRY)
        rst     28h
        db      7
        call    pmsg
        db      ", size ", 0
        ld      a,(L_SIZE + 2)
        rst     28h
        db      6
        ld      hl,(L_SIZE)
        rst     28h
        db      7
        call    pnl
        jp      ltaken

; DATA: the payload to LOAD + OFFSET
ldata:  ld      e,7                     ; 7: out of order
        ld      a,(L_OK)
        or      a
        jp      z,lrefuse
        ld      a,(F_HDR + 2)           ; OFFSET + LENGTH up to SIZE
        or      a
        jp      nz,lrefuse
        ld      a,(F_HDR + 5)
        ld      l,a
        ld      a,(F_HDR + 4)
        ld      h,a
        ld      de,(F_PLEN)
        add     hl,de
        ld      a,(F_HDR + 3)
        adc     a,0
        ld      c,a                     ; C:HL = the end
        ex      de,hl
        ld      hl,(L_SIZE)
        or      a
        sbc     hl,de
        ld      a,(L_SIZE + 2)
        sbc     a,c
        jp      c,lrefuse
        ld      a,(F_HDR + 5)           ; T_P = LOAD + OFFSET
        ld      l,a
        ld      a,(F_HDR + 4)
        ld      h,a
        ld      de,(L_LOAD)
        add     hl,de
        ld      (T_P),hl
        ld      a,(F_HDR + 3)
        ld      b,a
        ld      a,(L_LOAD + 2)
        adc     a,b
        ld      (T_P + 2),a
        ld      hl,(F_PLEN)
        ld      (T_NB),hl
        xor     a
        ld      (T_NB + 2),a
        ld      hl,RXBUF
        ld      (T_SRC),hl
.w:     ld      hl,(T_NB)                ; through window 5, a page at a time
        ld      a,h
        or      l
        jr      z,.done
        call    pmap
        push    hl
        call    pmin                    ; BC = this piece
        pop     de
        push    bc
        ld      hl,(T_SRC)
        ldir
        ld      (T_SRC),hl
        pop     bc
        call    padd
        jr      .w
.done:  ld      hl,(L_GOT)              ; the bytes so far
        ld      de,(F_PLEN)
        add     hl,de
        ld      (L_GOT),hl
        jr      nc,.d1
        ld      hl,L_GOT + 2
        inc     (hl)
.d1:    jp      ltaken

; END: ICRC over memory, then the ACTION (monitor.md, section 6.5)
lend:   ld      e,7
        ld      a,(L_OK)
        or      a
        jp      z,lrefuse
        ld      hl,(L_GOT)              ; every byte has come
        ld      de,(L_SIZE)
        or      a
        sbc     hl,de
        ld      a,(L_GOT + 2)
        ld      hl,L_SIZE + 2
        sbc     a,(hl)
        jp      c,lrefuse
        ld      hl,(L_LOAD)
        ld      (T_P),hl
        ld      a,(L_LOAD + 2)
        ld      (T_P + 2),a
        ld      hl,(L_SIZE)
        ld      (T_NB),hl
        ld      a,(L_SIZE + 2)
        ld      (T_NB + 2),a
        call    crcinit
.c:     ld      hl,(T_NB)
        ld      a,h
        or      l
        ld      hl,T_NB + 2
        or      (hl)
        jr      z,.chk
        call    pmap
        push    hl
        call    pmin
        pop     hl
        push    bc
        call    crcbuf
        pop     bc
        call    padd
        jr      .c
.chk:   ld      de,L_ICRC
        call    crcchk
        ld      e,6                     ; 6: memory does not match ICRC
        jp      nz,lrefuse
        ld      a,(F_SEQ)
        ld      (L_SEQ),a
        call    lk                      ; the reply before the ACTION
        ld      hl,(F_PLEN)             ; ACTION: 0 back to the monitor, 1 run
        ld      a,h
        or      l
        jr      z,.a
        ld      a,(RXBUF)
.a:     push    af
        call    lprog
        call    lback
        pop     af
        dec     a
        jp      z,c_go.nobp             ; 1: run it (a new run, from ENTRY)
        call    pmsg
        db      "Loaded.  PC = ", 0
        ld      hl,(M_PC)
        rst     28h
        db      7
        call    pnl
        jp      mloop

; A new program at ENTRY, with the registers and the map a program starts
; with (spec 16, section 6): back to the monitor, nothing stopped
lprog:  ld      hl,M_AF                 ; AF ... HL' 0
        ld      b,M_I - M_AF
.z:     ld      (hl),0
        inc     hl
        djnz    .z
        ld      hl,(L_ENTRY)
        ld      (M_PC),hl
        ld      (M_ENTRY),hl
        ld      hl,0xFFFE
        ld      (M_SP),hl
        ld      a,high ivt
        ld      (M_I),a
        ld      a,2
        ld      (M_IM),a
        xor     a
        ld      (M_R),a
        ld      (M_IFF),a
        ld      (M_RUN),a
        ld      (M_DBG),a
        ld      (M_LAST),a
        ld      (M_STEPF),a
        ld      (M_TAKEN),a             ; the console is the new program's screen
        ld      hl,progmap
        ld      de,M_MMU
        ld      bc,32
        ldir
        ld      hl,D_STOP               ; the debug stub's stop: ENTRY at ENTRY
        ld      b,15
.s:     ld      (hl),0
        inc     hl
        djnz    .s
        ld      hl,(M_PC)
        ld      a,h
        ld      (D_STOP + 4),a
        ld      a,l
        ld      (D_STOP + 5),a
        ret

; The 4 bytes at HL, HL - 1, HL - 2, HL - 3 to DE: big-endian to low byte first
be4:    ld      b,4
.l:     ld      a,(hl)
        ld      (de),a
        dec     hl
        inc     de
        djnz    .l
        ret
; Z if the 4 bytes at HL are those at DE (A, B, DE, HL changed)
cmp4:   ld      b,4
.l:     ld      a,(de)
        cp      (hl)
        ret     nz
        inc     hl
        inc     de
        djnz    .l
        ret

s_ready: db     "LOAD Z80 1", 13, 10
s_ready_end:
s_rimg: db      "RIMG"
s_z80:  db      "Z80 "
col_yellow: db  0x00, 0xFF, 0xFF        ; blue, green, red: the loader waits (spec 16, section 4.4)
