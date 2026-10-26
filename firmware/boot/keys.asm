; The keyboards and the serial link as key codes (spec 16, section 7.4;
; spec 12), in ROM page 0, included by boot.asm. A console core routine
; (console.asm): IY = the console's state, interrupts off.
;
;   k_poll   E = the next key code, or 0: a key put back (CS_PEND), then the
;            serial link (with its escape sequences), then the PS/2
;            keyboard, then the membrane, as CONMODE allows. One key a call;
;            the rest wait in the FIFOs
;   Serial   127 is Backspace (8); an LF straight after a CR is dropped; ESC
;            [ and ESC O sequences give the cursor and editing keys and
;            F1-F12; an ESC with nothing after it for 20 ms is Esc (27). At
;            the monitor's prompt an L is held back to see whether a HELLO
;            frame follows (hwatch, ticket #29)
;   PS/2     scan code set 2 (spec 12, section 3.3): F0 releases, E0
;            prefixes, both Shifts, Caps Lock, a UK layout (ps2tab,
;            ps2tab_s); the keyboard repeats keys itself
;   Membrane KEYMAP0-6 (the membrane alone, spec 12, section 5.3): a key that
;            has just gone down, through mtab: plain, with CAPS SHIFT
;            (capitals, the cursor keys, DELETE, EDIT, BREAK) or with SYMBOL
;            SHIFT (the Spectrum's symbols). Held, it repeats after 0.5 s,
;            ten times a second (TIME)

K_ESC_T equ     78                      ; 20 ms in TIME's 256 us steps
K_REP1  equ     1953                    ; 0.5 s
K_REP2  equ     391                     ; 0.1 s

k_poll: ld      e,27                    ; the stub's CONSOLE (CONMODE bit 4): no keys, Esc
        bit     4,(iy+CS_MODE)          ; at once (E's stepping, T)
        ret     nz
        ld      a,(iy+CS_PEND)
        or      a
        jr      z,.ser
        ld      e,a
        ld      (iy+CS_PEND),0
        ret
.ser:   bit     3,(iy+CS_MODE)
        jr      z,.kb
        ld      a,(iy+CS_SESC)          ; an escape sequence that stopped?
        or      a
        jr      z,.rx
        call    ktime
        ld      a,l
        sub     (iy+CS_STIME)
        ld      l,a
        ld      a,h
        sbc     a,(iy+CS_STIME+1)
        jr      nz,.late
        ld      a,l
        cp      K_ESC_T
        jr      c,.rx
.late:  ld      a,(iy+CS_SESC)
        ld      (iy+CS_SESC),0
        cp      1
        ld      e,27                    ; a lone ESC: Esc
        ret     z
.rx:    call    hheld                   ; an L held back too long: typed after all
        ld      a,e
        or      a
        ret     nz
        ld      a,(iy+CS_HRAW)          ; a byte held back after it
        or      a
        jr      z,.rx1
        ld      (iy+CS_HRAW),0
        ld      a,(iy+CS_HBYTE)
        jr      .rx2
.rx1:   ld      bc,SERSTAT1_P           ; RXCOUNT
        in      a,(c)
        or      a
        jr      z,.kb
        in      a,(SERDATA_PORT)
.rx2:   call    hwatch                  ; carry: the HELLO watch took it
        call    nc,sdec
        ld      a,e
        or      a
        ret     nz
        jr      .rx
.kb:    ld      e,0
        bit     2,(iy+CS_MODE)
        ret     z
.ps2:   ld      bc,KBSTAT_P
        in      a,(c)
        and     KBSTAT_COUNT_M
        jp      z,mscan
        in      a,(KBDATA_PORT)
        call    ps2key
        ld      a,e
        or      a
        ret     nz
        jr      .ps2

; ---- The monitor's prompt watches the link for a HELLO frame (debug.md,
; section 4.4; CS_HW set by mloop): an L is held back until the next byte
; shows it is no frame, or for 20 ms; L F then TYPE 0x10 gives the key
; KHELLO, and the monitor reads the rest of the frame. Bytes that turn out
; to be no frame are typed as they came. A = a byte from the link: carry
; and E = a key code or 0 if the watch took it; no carry (A kept) for sdec
hwatch: ld      e,a
        bit     0,(iy+CS_HW)
        jr      z,.no
        ld      a,(iy+CS_SESC)          ; not inside an escape sequence
        or      a
        jr      nz,.no
        ld      a,(iy+CS_HST)
        or      a
        jr      nz,.held
        ld      a,e
        cp      'L'
        jr      nz,.no
        ld      (iy+CS_HST),1
.stamp: call    ktime
        ld      (iy+CS_HTIME),l
        ld      (iy+CS_HTIME+1),h
        ld      e,0
        scf
        ret
.held:  dec     a
        jr      nz,.lf
        ld      a,e                     ; L held: F next?
        cp      'F'
        jr      nz,.give
        ld      (iy+CS_HST),2
        jr      .stamp
.lf:    ld      a,e                     ; L F held: HELLO's TYPE next?
        cp      0x10
        jr      nz,.give
        ld      (iy+CS_HST),0
        ld      e,KHELLO
        scf
        ret
.give:  ld      (iy+CS_HBYTE),e         ; no frame: the byte waits, the L (and F) are typed
        ld      (iy+CS_HRAW),1
        call    hrel
        scf
        ret
.no:    ld      a,e
        or      a
        ret
; E = 'L' if an L has been held back for 20 ms (the F, if one came, goes to
; CS_PEND), or 0
hheld:  ld      e,0
        ld      a,(iy+CS_HST)
        or      a
        ret     z
        call    ktime
        ld      a,l
        sub     (iy+CS_HTIME)
        ld      l,a
        ld      a,h
        sbc     a,(iy+CS_HTIME+1)
        jr      nz,hrel
        ld      a,l
        cp      K_ESC_T
        ret     c
; The L (and F) held back, typed: E = 'L'
hrel:   ld      a,(iy+CS_HST)
        ld      (iy+CS_HST),0
        dec     a
        jr      z,.l
        ld      (iy+CS_PEND),'F'
.l:     ld      e,'L'
        ret

; ---- A byte A from the serial link: E = a key code, or 0
sdec:   ld      e,0
        ld      c,a
        ld      a,(iy+CS_SESC)
        or      a
        jr      nz,.esc
        ld      a,c
        cp      10                      ; LF straight after CR
        jr      nz,.nlf
        bit     0,(iy+CS_CRLF)
        ld      (iy+CS_CRLF),0
        ret     nz
.nlf:   ld      (iy+CS_CRLF),0
        cp      13
        jr      nz,.ncr
        ld      (iy+CS_CRLF),1
.ncr:   cp      27
        jr      z,.e1
        cp      127
        jr      nz,.key
        ld      a,8
.key:   ld      e,a
        ret
.e1:    ld      (iy+CS_SESC),1          ; ESC: wait for the rest
        call    ktime
        ld      (iy+CS_STIME),l
        ld      (iy+CS_STIME+1),h
        ret
.esc:   ld      (iy+CS_SESC),0
        dec     a
        jr      nz,.e2
        ld      a,c                     ; ESC then:
        ld      (iy+CS_SESC),2
        cp      '['
        ret     z
        ld      (iy+CS_SESC),3
        cp      'O'
        ret     z
        ld      (iy+CS_SESC),0          ; anything else: Esc, and the byte after it
        cp      127
        jr      nz,.pend
        ld      a,8
.pend:  ld      (iy+CS_PEND),a
        ld      e,27
        ret
.e2:    dec     a
        jr      nz,.e3
        ld      a,c                     ; ESC [ then:
        ld      hl,sq_csi
        call    .look
        ret     nz
        ld      a,c
        sub     '0'
        cp      10
        ret     nc                      ; not known: dropped
        ld      (iy+CS_SNUM),a
        ld      (iy+CS_SESC),4
        ret
.e3:    dec     a
        jr      nz,.e4
        ld      a,c                     ; ESC O then P-S: F1-F4
        sub     'P'
        cp      4
        ret     nc
        add     a,145
        ld      e,a
        ret
.e4:    ld      a,c                     ; ESC [ digits then:
        cp      '~'
        jr      z,.tilde
        sub     '0'
        cp      10
        ret     nc
        ld      e,a
        ld      a,(iy+CS_SNUM)          ; x 10 + the digit (kept small)
        cp      25
        jr      c,.d10
        ld      a,25
.d10:   ld      b,a
        add     a,a
        add     a,a
        add     a,b
        add     a,a
        add     a,e
        ld      (iy+CS_SNUM),a
        ld      (iy+CS_SESC),4
        ld      e,0
        ret
.tilde: ld      a,(iy+CS_SNUM)
        ld      hl,sq_num
; Look A up in the table at HL (pairs: byte, key code; 0 ends it): E = the
; code and NZ, or Z
.look:  ld      b,a
.l:     ld      a,(hl)
        or      a
        ret     z
        inc     hl
        cp      b
        ld      a,(hl)
        inc     hl
        jr      nz,.l
        ld      e,a
        or      a
        ret

sq_csi: db      'A', 139, 'B', 138, 'C', 137, 'D', 136, 'H', 130, 'F', 131, 0
sq_num: db      1, 130, 2, 134, 3, 135, 4, 131, 5, 132, 6, 133
        db      15, 149, 17, 150, 18, 151, 19, 152, 20, 153, 21, 154, 23, 155, 24, 156, 0

; ---- One PS/2 byte A: E = a key code, or 0
ps2key: ld      e,0
        ld      (iy+CS_KLAST),a
        cp      0xF0
        jr      z,.f0
        cp      0xE0
        jr      z,.e0
        ld      c,a
        ld      b,(iy+CS_KF0)           ; B = released, D = extended; both cleared
        ld      d,(iy+CS_KE0)
        ld      (iy+CS_KF0),0
        ld      (iy+CS_KE0),0
        bit     0,d
        jr      nz,.ext
        cp      0x83                    ; F7, the one key above 0x7F
        jr      z,.f7
        cp      0x80                    ; AA, FA, E1 ...: not keys
        ret     nc
        cp      0x12                    ; the Shifts
        ld      e,1
        jr      z,.shift
        cp      0x59
        ld      e,2
        jr      z,.shift
        ld      e,0
        bit     0,b
        ret     nz                      ; any other key released
        cp      0x58                    ; Caps Lock
        jr      z,.caps
        ld      l,a
        ld      h,0
        ld      a,(iy+CS_KSH)
        or      a
        ld      de,ps2tab
        jr      z,.tab
        ld      de,ps2tab_s
.tab:   add     hl,de
        ld      a,(hl)
        ld      e,a
        or      a
        ret     z
        bit     0,(iy+CS_KCAPS)         ; Caps Lock: letters change case
        ret     z
        or      0x20
        cp      'a'
        ret     c
        cp      'z' + 1
        ret     nc
        ld      a,e
        xor     0x20
        ld      e,a
        ret
.f0:    ld      (iy+CS_KF0),1
        ret
.e0:    ld      (iy+CS_KE0),1
        ret
.shift: ld      a,(iy+CS_KSH)
        or      e
        bit     0,b
        jr      z,.sh
        xor     e
.sh:    ld      (iy+CS_KSH),a
        ld      e,0
        ret
.caps:  ld      a,(iy+CS_KCAPS)
        xor     1
        ld      (iy+CS_KCAPS),a
        ret
.f7:    bit     0,b
        ret     nz
        ld      e,151
        ret
.ext:   bit     0,b                     ; E0 keys: pressed only
        ret     nz
        ld      hl,ps2ext
        jp      sdec.look

; E0 keys: the cursor and editing keys, keypad Enter and /
ps2ext: db      0x6B, 136, 0x74, 137, 0x72, 138, 0x75, 139, 0x6C, 130, 0x69, 131
        db      0x7D, 132, 0x7A, 133, 0x70, 134, 0x71, 135, 0x5A, 13, 0x4A, '/', 0

; ---- The membrane: E = a key that has just gone down, a repeat, or 0.
; CAPS SHIFT and SYMBOL SHIFT are never keys themselves
mscan:  push    iy
        pop     hl
        ld      bc,CS_MPREV
        add     hl,bc                   ; HL = KEYMAP0-6 as last seen
        ld      bc,KEYMAP0_P            ; B = KEYMAP0, C = the system page
        ld      de,0                    ; D = 1 + the new key's place; E = 8 x column
.col:   in      a,(c)
        push    bc
        ld      b,a                     ; now
        ld      a,(hl)
        cpl
        and     b                       ; just pressed: now and not before
        ld      (hl),b
        ld      c,a
        ld      a,e
        or      a
        jr      nz,.n1
        res     0,c                     ; CAPS SHIFT
.n1:    cp      8
        jr      nz,.n2
        res     7,c                     ; SYMBOL SHIFT
.n2:    ld      a,d
        or      a
        jr      nz,.next                ; one key a call
        ld      a,c
        or      a
        jr      z,.next
        ld      d,e
.bit:   inc     d
        rrca
        jr      nc,.bit
.next:  pop     bc
        inc     hl
        inc     b
        ld      a,e
        add     a,8
        ld      e,a
        cp      56
        jr      c,.col
        ld      a,d
        or      a
        jr      z,.rep
        dec     d                       ; D = the place
        ld      l,d
        ld      h,0
        ld      bc,mtab_ss              ; SYMBOL SHIFT first, then CAPS SHIFT
        bit     7,(iy+CS_MPREV+1)
        jr      nz,.t
        ld      bc,mtab_cs
        bit     0,(iy+CS_MPREV)
        jr      nz,.t
        ld      bc,mtab
.t:     add     hl,bc
        ld      a,(hl)
        ld      e,a
        or      a
        ret     z
        ld      (iy+CS_RKEY),a
        ld      (iy+CS_RPOS),d
        ld      bc,K_REP1
        jr      .due
.rep:   ld      e,a                     ; (0)
        or      (iy+CS_RKEY)
        ret     z
        ld      a,(iy+CS_RPOS)          ; still held?
        ld      b,a
        rrca
        rrca
        rrca
        and     7
        add     a,CS_MPREV
        push    iy
        pop     hl
        ld      e,a
        ld      d,0
        add     hl,de
        ld      e,0
        ld      a,b
        and     7
        inc     a
        ld      b,a
        ld      a,(hl)
.sh:    rrca
        djnz    .sh
        jr      c,.held
        ld      (iy+CS_RKEY),0
        ret
.held:  call    ktime
        ld      a,l
        sub     (iy+CS_RTIME)
        ld      a,h
        sbc     a,(iy+CS_RTIME+1)
        ret     m                       ; not yet
        ld      e,(iy+CS_RKEY)
        ld      bc,K_REP2
.due:   push    bc                      ; the next repeat: now + BC
        call    ktime
        pop     bc
        add     hl,bc
        ld      (iy+CS_RTIME),l
        ld      (iy+CS_RTIME+1),h
        ret

; Keyboard tables: the membrane by 8 x column + row, plain, with CAPS SHIFT
; and with SYMBOL SHIFT; then PS/2 set 2 codes 0x00-0x7F, UK layout,
; unshifted and shifted. 0: no key. 0x9C is the font's pound sign, 0xAA its
; not sign. Key codes (spec 16, section 7.4): 8 Backspace, 9 Tab (EDIT),
; 13 Enter, 27 Esc (BREAK), 130-135 Home End PgUp PgDn Ins Del, 136-139
; Left Right Down Up, 145-156 F1-F12 (GRAPH gives F1). Columns 5 and 6 are the Next's extra
; keys (spec 12, section 5.4): EXTEND, CAPS LOCK, TRUE VIDEO, BREAK, ;  ,
; DELETE, left; up, GRAPH, INV VIDEO, EDIT, "  .  right, down
mtab:
        db      0, 'a', 'q', '1', '0', 'p', 13, ' '     ; column 0, rows 0-7
        db      'z', 's', 'w', '2', '9', 'o', 'l', 0    ; column 1
        db      'x', 'd', 'e', '3', '8', 'i', 'k', 'm'  ; column 2
        db      'c', 'f', 'r', '4', '7', 'u', 'j', 'n'  ; column 3
        db      'v', 'g', 't', '5', '6', 'y', 'h', 'b'  ; column 4
        db      0, 0, 0, 27, ';', ',', 8, 136           ; column 5
        db      139, 145, 0, 9, '"', '.', 137, 138      ; column 6: GRAPH is F1
mtab_cs:
        db      0, 'A', 'Q', 9, 8, 'P', 13, 27          ; column 0: EDIT, DELETE, BREAK
        db      'Z', 'S', 'W', 0, 145, 'O', 'L', 0      ; 9: GRAPH (F1)
        db      'X', 'D', 'E', 0, 137, 'I', 'K', 'M'    ; 8: right
        db      'C', 'F', 'R', 0, 139, 'U', 'J', 'N'    ; 7: up
        db      'V', 'G', 'T', 136, 138, 'Y', 'H', 'B'  ; 5: left, 6: down
        db      0, 0, 0, 27, ';', ',', 8, 136
        db      139, 145, 0, 9, '"', '.', 137, 138
mtab_ss:
        db      0, '~', 0, '!', '_', '"', 13, ' '
        db      ':', '|', 0, '@', ')', ';', '=', 0
        db      0x9C, 0x5C, 0, '#', '(', 0, '+', '.'
        db      '?', '{', '<', '$', "'", ']', '-', ','
        db      '/', '}', '>', '%', '&', '[', '^', '*'
        db      0, 0, 0, 27, ';', ',', 8, 136
        db      139, 0, 0, 9, '"', '.', 137, 138
ps2tab:
        db      0, 153, 0, 149, 147, 145, 146, 156      ; 0x00-0x07: F9 F5 F3 F1 F2 F12
        db      0, 154, 152, 150, 148, 0x09, '`', 0     ; 0x08-0x0F: F10 F8 F6 F4 Tab
        db      0, 0, 0, 0, 0, 'q', '1', 0              ; 0x10-0x17
        db      0, 0, 'z', 's', 'a', 'w', '2', 0        ; 0x18-0x1F
        db      0, 'c', 'x', 'd', 'e', '4', '3', 0      ; 0x20-0x27
        db      0, ' ', 'v', 'f', 't', 'r', '5', 0      ; 0x28-0x2F
        db      0, 'n', 'b', 'h', 'g', 'y', '6', 0      ; 0x30-0x37
        db      0, 0, 'm', 'j', 'u', '7', '8', 0        ; 0x38-0x3F
        db      0, ',', 'k', 'i', 'o', '0', '9', 0      ; 0x40-0x47
        db      0, '.', '/', 'l', ';', 'p', '-', 0      ; 0x48-0x4F
        db      0, 0, "'", 0, '[', '=', 0, 0            ; 0x50-0x57
        db      0, 0, 0x0D, ']', 0, '#', 0, 0           ; 0x58-0x5F
        db      0, 0x5C, 0, 0, 0, 0, 0x08, 0            ; 0x60-0x67
        db      0, '1', 0, '4', '7', 0, 0, 0            ; 0x68-0x6F
        db      '0', '.', '2', '5', '6', '8', 0x1B, 0   ; 0x70-0x77
        db      155, '+', '3', '-', '*', '9', 0, 0      ; 0x78-0x7F: F11
ps2tab_s:
        db      0, 153, 0, 149, 147, 145, 146, 156
        db      0, 154, 152, 150, 148, 0x09, 0xAA, 0
        db      0, 0, 0, 0, 0, 'Q', '!', 0
        db      0, 0, 'Z', 'S', 'A', 'W', '"', 0
        db      0, 'C', 'X', 'D', 'E', '$', 0x9C, 0
        db      0, ' ', 'V', 'F', 'T', 'R', '%', 0
        db      0, 'N', 'B', 'H', 'G', 'Y', '^', 0
        db      0, 0, 'M', 'J', 'U', '&', '*', 0
        db      0, '<', 'K', 'I', 'O', ')', '(', 0
        db      0, '>', '?', 'L', ':', 'P', '_', 0
        db      0, 0, '@', 0, '{', '+', 0, 0
        db      0, 0, 0x0D, '}', 0, '~', 0, 0
        db      0, '|', 0, 0, 0, 0, 0x08, 0
        db      0, '1', 0, '4', '7', 0, 0, 0
        db      '0', '.', '2', '5', '6', '8', 0x1B, 0
        db      155, '+', '3', '-', '*', '9', 0, 0
