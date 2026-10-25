; The boot console's keyboards and joysticks (spec 12; ticket #19), included
; by console.asm. Typed keys go to conkey, as bytes from the serial link do.
;
;   PS/2     kbon turns the PS/2 FIFO on with its KEYB interrupt (spec 8,
;            source 17). kbint, the handler, empties the FIFO into a
;            256-byte ring in SRAM (KBUF); the main loop calls kbpoll, which
;            decodes scan code set 2 (spec 12, section 3.3): F0 releases, E0
;            prefixes, both Shifts, Caps Lock; a UK layout table (ps2tab,
;            ps2tab_s) for the main keys and the keypad, E0 5A (keypad
;            Enter), E0 4A (keypad /) and E0 71 (Delete)
;   Membrane memscan reads KEYMAP0-6 (the membrane alone, spec 12, section
;            5.3) and types each key that has just gone down, through mtab:
;            8 x column + row, plain, with CAPS SHIFT (capitals, CAPS SHIFT
;            + 0 DELETE) or with SYMBOL SHIFT (the Spectrum's symbols)
;   Status   instat keeps joystick 1 (read through the Kempston port 0x1F),
;            joystick 2 (JOY2) and port 0xFE with all rows (A15-A8 = 0) for
;            the status line, and asks for it to be drawn again when one
;            changes; kbpoll keeps the last PS/2 byte (KLAST)

KTAIL   equ     0xC010                  ; the ring: where kbint puts the next byte
KHEAD   equ     0xC011                  ; ... and where kbpoll takes the next
KF0     equ     0xC012                  ; 1: F0 came (the next key is released)
KE0     equ     0xC013                  ; 1: E0 came (must follow KF0)
KSHIFT  equ     0xC014                  ; Shifts held: bit 0 left, bit 1 right
KCAPS   equ     0xC015                  ; Caps Lock: bit 0
KLAST   equ     0xC016                  ; the last PS/2 byte, for the status line
SJOY1   equ     0xC017                  ; the status line's joystick 1 (Kempston) ...
SJOY2   equ     0xC018                  ; ... joystick 2 ...
SFE     equ     0xC019                  ; ... and port 0xFE, all rows
MPREV   equ     0xC01A                  ; 7 bytes: KEYMAP0-6 last seen
KBUF    equ     0xC100                  ; the 256-byte ring (page aligned)

; The variables cleared (conprep, before the status line is first drawn; A,
; B, HL changed)
kbinit: ld      hl,KTAIL
        ld      b,MPREV + 7 - KTAIL
.clr:   ld      (hl),0
        inc     hl
        djnz    .clr
        ld      a,0xFF                  ; port 0xFE with nothing pressed
        ld      (SFE),a
        ret

; The PS/2 FIFO and its interrupt on (A, B, C changed)
kbon:   ld      bc,KBCON_P
        ld      a,KBCON_EN_M
        out     (c),a
        ld      b,KBIRQEN
        ld      a,KBIRQEN_DATA_M        ; KEYB while the FIFO is not empty
        out     (c),a
        ld      bc,INTENA0_P + (INTR_KEYB << 8)
        ld      a,INTENA_SETCLR_M | (1 << INTB_KEYB)
        out     (c),a                   ; the controller's enable
        ret

; KEYB: every byte waiting (KBSTAT.COUNT) into the ring. The request drops
; when the FIFO is empty
kbint:  push    af
        push    bc
        push    hl
.more:  ld      bc,KBSTAT_P
        in      a,(c)
        and     KBSTAT_COUNT_M
        jr      z,.done
        ld      b,a
        ld      h,high KBUF
        ld      a,(KTAIL)
        ld      l,a
.rd:    in      a,(KBDATA_PORT)
        ld      (hl),a
        inc     l                       ; round the ring's page
        djnz    .rd
        ld      a,l
        ld      (KTAIL),a
        jr      .more
.done:  pop     hl
        pop     bc
        pop     af
        ei
        reti

; Decode every byte in the ring (A, B, C, D, E, HL changed)
kbpoll: ld      a,(KHEAD)
        ld      l,a
        ld      a,(KTAIL)
        cp      l
        ret     z
        ld      h,high KBUF
        ld      c,(hl)
        inc     l
        ld      a,l
        ld      (KHEAD),a
        ld      a,c
        call    ps2key
        jr      kbpoll

; One PS/2 byte in A
ps2key: ld      (KLAST),a
        ld      c,a
        ld      a,1
        ld      (CDIRTY),a
        ld      a,c
        cp      0xF0
        jr      z,.f0
        cp      0xE0
        jr      z,.e0
        ld      hl,KF0                  ; B = released, D = extended; both cleared
        ld      b,(hl)
        ld      (hl),0
        inc     hl
        ld      d,(hl)
        ld      (hl),0
        cp      0x80                    ; AA, FA, E1 ...: not keys
        ret     nc
        bit     0,d
        jr      nz,.ext
        cp      0x12                    ; the Shifts
        ld      e,1
        jr      z,.shift
        cp      0x59
        ld      e,2
        jr      z,.shift
        bit     0,b
        ret     nz                      ; any other key released
        cp      0x58                    ; Caps Lock
        jr      z,.caps
        ld      l,a
        ld      h,0
        ld      a,(KSHIFT)
        or      a
        ld      de,ps2tab
        jr      z,.tab
        ld      de,ps2tab_s
.tab:   add     hl,de
        ld      a,(hl)
        or      a
        ret     z
        ld      c,a
        ld      a,(KCAPS)               ; Caps Lock: letters change case
        rrca
        ld      a,c
        jr      nc,.key
        or      0x20
        cp      'a'
        jr      c,.nl
        cp      'z' + 1
        jr      nc,.nl
        ld      a,c
        xor     0x20
        jr      .key
.nl:    ld      a,c
.key:   jp      conkey
.f0:    ld      a,1
        ld      (KF0),a
        ret
.e0:    ld      a,1
        ld      (KE0),a
        ret
.shift: ld      a,(KSHIFT)
        or      e
        bit     0,b
        jr      z,.sh
        xor     e
.sh:    ld      (KSHIFT),a
        ret
.caps:  ld      a,(KCAPS)
        xor     1
        ld      (KCAPS),a
        ret
.ext:   bit     0,b                     ; E0 keys: pressed only
        ret     nz
        ld      c,13                    ; keypad Enter
        cp      0x5A
        jr      z,.ek
        ld      c,'/'                   ; keypad /
        cp      0x4A
        jr      z,.ek
        ld      c,127                   ; Delete
        cp      0x71
        ret     nz
.ek:    ld      a,c
        jp      conkey

; The membrane: each key that has gone down since the last call is typed
; (A, B, C, D, E, HL changed)
memscan:
        ld      hl,MPREV
        ld      bc,KEYMAP0_P            ; B = KEYMAP0, C = the system page
        ld      e,0                     ; 8 x column
.col:   in      a,(c)
        ld      d,a
        xor     (hl)
        and     d                       ; just pressed
        ld      (hl),d
        jr      z,.next
        push    bc
        push    de
        push    hl
        ld      c,a
        ld      b,8
.row:   rr      c
        jr      nc,.nr
        push    bc
        push    de
        ld      a,e
        call    mkey
        pop     de
        pop     bc
.nr:    inc     e
        djnz    .row
        pop     hl
        pop     de
        pop     bc
.next:  inc     hl
        inc     b
        ld      a,e
        add     a,8
        ld      e,a
        cp      56
        jr      c,.col
        ret

; Key A (8 x column + row) typed, with the shift held: SYMBOL SHIFT (row 7
; of column 1) first, then CAPS SHIFT (row 0 of column 0)
mkey:   ld      l,a
        ld      h,0
        ld      de,mtab_ss
        ld      a,(MPREV + 1)
        bit     7,a
        jr      nz,.t
        ld      de,mtab_cs
        ld      a,(MPREV)
        bit     0,a
        jr      nz,.t
        ld      de,mtab
.t:     add     hl,de
        ld      a,(hl)
        or      a
        ret     z
        jp      conkey

; The status line's inputs: joystick 1 through the Kempston port, joystick 2
; and port 0xFE with every row; CDIRTY when one has changed (A, B, C, HL
; changed)
instat: in      a,(KEMPSTON_PORT)
        ld      hl,SJOY1
        call    .upd
        ld      bc,JOY2_P
        in      a,(c)
        inc     hl
        call    .upd
        xor     a                       ; A15-A8 = 0: all eight rows
        in      a,(ULA_PORT)
        inc     hl
.upd:   cp      (hl)
        ret     z
        ld      (hl),a
        ld      a,1
        ld      (CDIRTY),a
        ret

; The status line's letters for a joystick: mask, letter, then 0. U D L R, 1 and 2
; (Fire 1 / B, Fire 2 / C), A, S (START)
joybits: db     0x08, 'U', 0x04, 'D', 0x02, 'L', 0x01, 'R'
        db      0x10, '1', 0x20, '2', 0x40, 'A', 0x80, 'S', 0

; Keyboard tables (written by a short script from these layouts): the
; membrane by 8 x column + row, plain, with CAPS SHIFT and with SYMBOL
; SHIFT; then PS/2 set 2 codes 0x00-0x7F, UK layout, unshifted and shifted.
; 0: no character. 0x9C is the font's pound sign, 0xAA its not sign. 0x09
; (Tab) is EDIT, CAPS SHIFT + 1 or the Next's EDIT key (column 6, row 3),
; which plays the port 0xFE demo (tape.asm)
mtab:
        db      0, 'a', 'q', '1', '0', 'p', 0x0D, ' '   ; column 0, rows 0-7
        db      'z', 's', 'w', '2', '9', 'o', 'l', 0   ; column 1, rows 0-7
        db      'x', 'd', 'e', '3', '8', 'i', 'k', 'm'   ; column 2, rows 0-7
        db      'c', 'f', 'r', '4', '7', 'u', 'j', 'n'   ; column 3, rows 0-7
        db      'v', 'g', 't', '5', '6', 'y', 'h', 'b'   ; column 4, rows 0-7
        db      0, 0, 0, 0, ';', ',', 0x08, 0   ; column 5, rows 0-7
        db      0, 0, 0, 0x09, '"', '.', 0, 0   ; column 6, rows 0-7
mtab_cs:
        db      0, 'A', 'Q', 0x09, 0x08, 'P', 0x0D, 0   ; column 0, rows 0-7
        db      'Z', 'S', 'W', 0, 0, 'O', 'L', 0   ; column 1, rows 0-7
        db      'X', 'D', 'E', 0, 0, 'I', 'K', 'M'   ; column 2, rows 0-7
        db      'C', 'F', 'R', 0, 0, 'U', 'J', 'N'   ; column 3, rows 0-7
        db      'V', 'G', 'T', 0, 0, 'Y', 'H', 'B'   ; column 4, rows 0-7
        db      0, 0, 0, 0, ';', ',', 0x08, 0   ; column 5, rows 0-7
        db      0, 0, 0, 0x09, '"', '.', 0, 0   ; column 6, rows 0-7
mtab_ss:
        db      0, '~', 0, '!', '_', '"', 0x0D, ' '   ; column 0, rows 0-7
        db      ':', '|', 0, '@', ')', ';', '=', 0   ; column 1, rows 0-7
        db      0x9C, 0x5C, 0, '#', '(', 0, '+', '.'   ; column 2, rows 0-7
        db      '?', '{', '<', '$', "'", ']', '-', ','   ; column 3, rows 0-7
        db      '/', '}', '>', '%', '&', '[', '^', '*'   ; column 4, rows 0-7
        db      0, 0, 0, 0, ';', ',', 0x08, 0   ; column 5, rows 0-7
        db      0, 0, 0, 0x09, '"', '.', 0, 0   ; column 6, rows 0-7
ps2tab:
        db      0, 0, 0, 0, 0, 0, 0, 0   ; 0x00-0x07
        db      0, 0, 0, 0, 0, 0x09, '`', 0   ; 0x08-0x0F
        db      0, 0, 0, 0, 0, 'q', '1', 0   ; 0x10-0x17
        db      0, 0, 'z', 's', 'a', 'w', '2', 0   ; 0x18-0x1F
        db      0, 'c', 'x', 'd', 'e', '4', '3', 0   ; 0x20-0x27
        db      0, ' ', 'v', 'f', 't', 'r', '5', 0   ; 0x28-0x2F
        db      0, 'n', 'b', 'h', 'g', 'y', '6', 0   ; 0x30-0x37
        db      0, 0, 'm', 'j', 'u', '7', '8', 0   ; 0x38-0x3F
        db      0, ',', 'k', 'i', 'o', '0', '9', 0   ; 0x40-0x47
        db      0, '.', '/', 'l', ';', 'p', '-', 0   ; 0x48-0x4F
        db      0, 0, "'", 0, '[', '=', 0, 0   ; 0x50-0x57
        db      0, 0, 0x0D, ']', 0, '#', 0, 0   ; 0x58-0x5F
        db      0, 0x5C, 0, 0, 0, 0, 0x08, 0   ; 0x60-0x67
        db      0, '1', 0, '4', '7', 0, 0, 0   ; 0x68-0x6F
        db      '0', '.', '2', '5', '6', '8', 0x1B, 0   ; 0x70-0x77
        db      0, '+', '3', '-', '*', '9', 0, 0   ; 0x78-0x7F
ps2tab_s:
        db      0, 0, 0, 0, 0, 0, 0, 0   ; 0x00-0x07
        db      0, 0, 0, 0, 0, 0x09, 0xAA, 0   ; 0x08-0x0F
        db      0, 0, 0, 0, 0, 'Q', '!', 0   ; 0x10-0x17
        db      0, 0, 'Z', 'S', 'A', 'W', '"', 0   ; 0x18-0x1F
        db      0, 'C', 'X', 'D', 'E', '$', 0x9C, 0   ; 0x20-0x27
        db      0, ' ', 'V', 'F', 'T', 'R', '%', 0   ; 0x28-0x2F
        db      0, 'N', 'B', 'H', 'G', 'Y', '^', 0   ; 0x30-0x37
        db      0, 0, 'M', 'J', 'U', '&', '*', 0   ; 0x38-0x3F
        db      0, '<', 'K', 'I', 'O', ')', '(', 0   ; 0x40-0x47
        db      0, '>', '?', 'L', ':', 'P', '_', 0   ; 0x48-0x4F
        db      0, 0, '@', 0, '{', '+', 0, 0   ; 0x50-0x57
        db      0, 0, 0x0D, '}', 0, '~', 0, 0   ; 0x58-0x5F
        db      0, '|', 0, 0, 0, 0, 0x08, 0   ; 0x60-0x67
        db      0, '1', 0, '4', '7', 0, 0, 0   ; 0x68-0x6F
        db      '0', '.', '2', '5', '6', '8', 0x1B, 0   ; 0x70-0x77
        db      0, '+', '3', '-', '*', '9', 0, 0   ; 0x78-0x7F
