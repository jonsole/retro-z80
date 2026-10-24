; Memory and MMU self-test (spec 2, sections 9-11; spec 3, section 6).
; Included by the boot ROM and by sim/systest.
;
;   call selftest     A = 0 and Z set if every check passed; otherwise A and
;                     D are the number of the first check that failed (0x41
;                     up) and Z is clear
;
; Runs from window 0 (boot ROM page 0) with its stack in window 7 (SRAM page
; 5, never touched here), and uses windows 2-6. At the end, passed or not,
; windows 2-6 are back at the reset mapping (SRAM pages 0-4, write = read),
; so the caller's memory is where it was; the contents of SRAM pages 0-4 and
; of the pages tested are not kept. Changes A, B, C, D, E, H, L, IX.
;
; The caller's ROM must have "jp st_rst38" at 0x0038: an opcode fetch from
; the register page reads 0xFF (RST 38h), and check 0x4C makes one.
;
; Keeps clear of SRAM pages 0x0C0-0x0FF and 0x1C0-0x1FF (physical 0x180000
; and 0x380000 up): the testbench keeps its DMA load there (sim/tb.v, +dma).

; MMU page numbers (spec 2, section 9.3)
PG_REGS equ     0x3F8                   ; the register page
PG_NONE equ     0x3FB                   ; reads 0xFF, ignores writes
PG_ROM0 equ     0x3FC                   ; boot ROM page 0
PG_ROM1 equ     0x3FD                   ; boot ROM page 1

W2      equ     0x4000                  ; window 2
W3      equ     0x6000                  ; window 3

selftest:
        ld      ix,0
        add     ix,sp                   ; for st_fail, from any depth

        ; ---- reset state, through the ports
        ld      d,0x41                  ; check 41: every MMU register reads its reset value
        ld      hl,st_reset
        ld      bc,MMU0_0_P
.reset: in      a,(c)
        cp      (hl)
        jp      nz,st_fail
        inc     hl
        inc     b
        ld      a,b
        cp      0xA0                    ; past MMU7W_1
        jr      nz,.reset

        ; ---- byte 0 is held, byte 1 commits (spec 2, section 9.2)
        ld      a,0xA1
        ld      (W2),a                  ; SRAM page 0
        ld      d,0x42                  ; check 42: byte 0 alone changes nothing
        ld      bc,MMU2_0_P
        ld      a,0x10
        out     (c),a
        in      a,(c)
        or      a                       ; still reads page 0
        jp      nz,st_fail
        ld      a,(W2)
        cp      0xA1                    ; and window 2 still shows page 0
        jp      nz,st_fail
        ld      d,0x43                  ; check 43: byte 1 commits the read and the write page
        inc     b                       ; MMU2_1
        xor     a
        out     (c),a                   ; page 0x010
        ld      a,0xB2
        ld      (W2),a
        ld      b,MMU2_0
        in      a,(c)
        cp      0x10
        jp      nz,st_fail
        ld      b,MMU2W_0
        in      a,(c)
        cp      0x10
        jp      nz,st_fail
        ld      hl,0x0000
        ld      b,MMU2_0
        call    st_map                  ; window 2 back to page 0
        ld      a,(W2)
        cp      0xA1
        jp      nz,st_fail
        ld      hl,0x0010
        ld      b,MMU3_0
        call    st_map                  ; window 3 shows page 0x010
        ld      a,(W3)
        cp      0xB2                    ; the write went to page 0x010
        jp      nz,st_fail
        ld      d,0x44                  ; check 44: byte 1 alone keeps bits 7-0
        ld      bc,MMU3_1_P
        ld      a,1
        out     (c),a                   ; page 0x110
        dec     b
        in      a,(c)
        cp      0x10
        jp      nz,st_fail
        inc     b
        in      a,(c)
        cp      1
        jp      nz,st_fail
        ld      b,MMU3W_0
        in      a,(c)
        cp      0x10
        jp      nz,st_fail
        inc     b
        in      a,(c)
        cp      1
        jp      nz,st_fail
        ld      d,0x45                  ; check 45: a write to another register between the bytes
        ld      bc,MMU4_0_P
        ld      a,0x20
        out     (c),a                   ; window 4: 0x20 held
        ld      hl,0x0021
        ld      b,MMU5_0
        call    st_map                  ; window 5: 0x021, committed
        ld      bc,MMU4_1_P
        xor     a
        out     (c),a                   ; window 4: commits 0x020
        dec     b
        in      a,(c)
        cp      0x20
        jp      nz,st_fail
        ld      b,MMU5_0
        in      a,(c)
        cp      0x21
        jp      nz,st_fail

        ; ---- split read and write pages
        ld      hl,0x0000
        ld      b,MMU2_0
        call    st_map
        ld      d,0x46                  ; check 46: a write page commit splits the window
        ld      hl,0x0011
        ld      b,MMU2W_0
        call    st_map                  ; window 2 reads page 0, writes page 0x011
        ld      bc,MMU2_0_P
        in      a,(c)
        or      a
        jp      nz,st_fail
        ld      a,0xD4
        ld      (W2),a
        ld      a,(W2)
        cp      0xA1                    ; read from page 0
        jp      nz,st_fail
        ld      hl,0x0011
        ld      b,MMU3_0
        call    st_map
        ld      a,(W3)
        cp      0xD4                    ; written to page 0x011
        jp      nz,st_fail
        ld      d,0x47                  ; check 47: a read page commit joins them again
        ld      bc,MMU2_1_P
        xor     a
        out     (c),a                   ; byte 1 alone: page 0 again
        ld      b,MMU2W_0
        in      a,(c)
        or      a
        jp      nz,st_fail
        ld      a,0xE5
        ld      (W2),a
        ld      a,(W3)
        cp      0xD4                    ; page 0x011 not written
        jp      nz,st_fail
        ld      a,(W2)
        cp      0xE5
        jp      nz,st_fail

        ; ---- NONE and reserved pages
        ld      d,0x48                  ; check 48: NONE as a write page ignores writes
        ld      hl,PG_NONE
        ld      b,MMU2W_0
        call    st_map
        ld      a,0x66
        ld      (W2),a
        ld      a,(W2)
        cp      0xE5
        jp      nz,st_fail
        ld      d,0x49                  ; check 49: NONE and reserved pages read 0xFF
        ld      hl,st_ffpages
.ff:    ld      e,(hl)
        inc     hl
        ld      a,(hl)
        inc     hl
        cp      0xFF
        jr      z,.ffend
        push    hl
        ld      h,a
        ld      l,e
        ld      b,MMU3_0
        call    st_map
        ld      a,0x77
        ld      (W3+0x123),a            ; ignored
        ld      a,(W3+0x123)
        pop     hl
        cp      0xFF
        jp      nz,st_fail
        jr      .ff
.ffend:

        ; ---- boot ROM pages (SYSCON.ROMWE is 0)
        ld      d,0x4A                  ; check 4A: ROM pages read the boot ROM and ignore writes
        ld      hl,PG_ROM0
        ld      b,MMU3_0
        call    st_map
        ld      hl,0
        ld      de,W3
        ld      b,16
.rom:   ld      a,(de)
        cp      (hl)
        jr      nz,.romf
        cpl
        ld      (de),a                  ; ignored
        ld      a,(de)
        cp      (hl)
        jr      nz,.romf
        inc     hl
        inc     de
        djnz    .rom
        ld      hl,PG_ROM1
        ld      b,MMU3_0
        call    st_map
        ld      a,(W3)
        ld      hl,0x2000
        cp      (hl)                    ; window 1 is ROM page 1
        jr      z,.romok
.romf:  ld      d,0x4A
        jp      st_fail
.romok:

        ; ---- the register page (spec 3, section 6)
        ld      d,0x4B                  ; check 4B: registers through the register page
        ld      hl,PG_REGS
        ld      b,MMU3_0
        call    st_map                  ; window 3: registers at 0x6000
        ld      a,(W3+SYSID)
        ld      bc,SYSID_P
        in      e,(c)
        cp      e                       ; SYSID the same both ways
        jp      nz,st_fail
        cp      0x5A
        jp      nz,st_fail
        ld      a,(W3+MMU3_0)
        cp      PG_REGS & 0xFF
        jp      nz,st_fail
        ld      a,(W3+MMU3_1)
        cp      PG_REGS >> 8
        jp      nz,st_fail
        ld      hl,0x0022
        ld      (W3+MMU4),hl            ; one instruction: byte 0, then byte 1 commits
        ld      bc,MMU4_0_P
        in      a,(c)
        cp      0x22
        jp      nz,st_fail
        ld      bc,MMU5_0_P
        ld      a,0x23
        out     (c),a                   ; byte 0 by port
        xor     a
        ld      (W3+MMU5_1),a           ; byte 1 through memory commits it
        ld      a,(W3+MMU5_0)
        cp      0x23
        jp      nz,st_fail
        ld      hl,st_ffoffs
.ffo:   ld      e,(hl)
        inc     hl
        ld      a,(hl)
        inc     hl
        cp      0xFF
        jr      z,.ffoend
        push    hl
        ld      h,a
        ld      l,e
        ld      a,(hl)
        pop     hl
        cp      0xFF                    ; reserved or no unit yet: 0xFF
        jp      nz,st_fail
        jr      .ffo
.ffoend:
        ld      d,0x4C                  ; check 4C: an opcode fetch from the register page is RST 38h
        ld      hl,0
        call    W3+REGS_KEYROW          ; reads 0xFF: RST 38h, st_rst38 returns here
        ld      a,h
        cp      (W3+REGS_KEYROW+1) >> 8
        jp      nz,st_fail
        ld      a,l
        cp      (W3+REGS_KEYROW+1) & 0xFF
        jp      nz,st_fail
        ld      d,0x4D                  ; check 4D: ROM reads, register writes in one window
        ld      hl,PG_ROM0
        ld      b,MMU6_0
        call    st_map
        ld      hl,PG_REGS
        ld      b,MMU6W_0
        call    st_map                  ; window 6 (0xC000) reads ROM, writes registers
        ld      hl,0x0024
        ld      (0xC000+MMU4),hl        ; window 4: page 0x024
        ld      bc,MMU4_0_P
        in      a,(c)
        cp      0x24
        jp      nz,st_fail
        ld      a,(0xC000+MMU4)
        ld      hl,MMU4
        cp      (hl)                    ; reads the ROM, as window 0 does
        jp      nz,st_fail

        ; ---- SRAM size and mirror (spec 2, section 11)
        ld      d,0x4E                  ; check 4E: SYSCFG.CHIPMB is 2 or 4, and pages 0x100-0x1FF
        ld      bc,SYSCFG_P             ; are their own on a 4 MB build, a mirror on a 2 MB one
        in      a,(c)
        and     SYSCFG_CHIPMB_M
        ld      e,a
        ld      hl,0x0020
        ld      b,MMU2_0
        call    st_map
        ld      hl,0x0120
        ld      b,MMU3_0
        call    st_map
        ld      a,0x5A
        ld      (W2),a                  ; page 0x020
        ld      a,0xA5
        ld      (W3),a                  ; page 0x120
        ld      a,e
        cp      4 << SYSCFG_CHIPMB_B
        ld      a,0x5A
        jr      z,.mb
        ld      a,e
        cp      2 << SYSCFG_CHIPMB_B
        jp      nz,st_fail
        ld      a,0xA5
.mb:    ld      hl,W2
        cp      (hl)
        jp      nz,st_fail

        ; ---- SRAM data and address lines, through the MMU
        ld      d,0x4F                  ; check 4F: data lines, even and odd bytes
        ld      hl,0x0030
        ld      b,MMU2_0
        call    st_map
        ld      hl,W2
        ld      a,1
.data:  ld      (hl),a
        inc     hl
        cpl
        ld      (hl),a
        cpl
        dec     hl
        cp      (hl)
        jp      nz,st_fail
        inc     hl
        cpl
        cp      (hl)
        jp      nz,st_fail
        cpl
        dec     hl
        add     a,a
        jr      nc,.data
        ld      d,0x50                  ; check 50: address lines A0-A12 within a page
        ld      hl,W2
        ld      (hl),0
        ld      de,1
        ld      c,1
.aw:    push    hl
        add     hl,de
        ld      (hl),c
        pop     hl
        inc     c
        ex      de,hl
        add     hl,hl
        ex      de,hl
        bit     5,d                     ; up to offset 0x1000
        jr      z,.aw
        ld      a,(hl)
        or      a
        ld      d,0x50
        jp      nz,st_fail
        ld      de,1
        ld      c,1
.ar:    push    hl
        add     hl,de
        ld      a,(hl)
        pop     hl
        cp      c
        jr      nz,.arf
        inc     c
        ex      de,hl
        add     hl,hl
        ex      de,hl
        bit     5,d
        jr      z,.ar
        jr      .pages
.arf:   ld      d,0x50
        jp      st_fail
.pages: ld      d,0x51                  ; check 51: page lines: pages 0x000 and 0x001-0x080
        ld      hl,0x0000               ; (and 0x100 on a 4 MB build)
        ld      e,0x55                  ; value for page 0
        call    st_pw
        ld      hl,1
.pw:    ld      e,l
        call    st_pw
        add     hl,hl
        bit     0,h
        jr      z,.pw
        ld      bc,SYSCFG_P
        in      a,(c)
        cp      4 << SYSCFG_CHIPMB_B
        ld      hl,0x0100
        ld      e,0x81
        call    z,st_pw
        ld      hl,0x0000
        ld      e,0x55
        call    st_pr
        ld      hl,1
.pr:    ld      e,l
        call    st_pr
        add     hl,hl
        bit     0,h
        jr      z,.pr
        ld      bc,SYSCFG_P
        in      a,(c)
        cp      4 << SYSCFG_CHIPMB_B
        ld      hl,0x0100
        ld      e,0x81
        call    z,st_pr

        call    st_restore
        xor     a
        ret

; Write E at the start of SRAM page HL (window 2)
st_pw:  push    hl
        ld      b,MMU2_0
        call    st_map
        ld      a,e
        ld      (W2),a
        pop     hl
        ret

; Check E at the start of SRAM page HL (window 2)
st_pr:  push    hl
        ld      b,MMU2_0
        call    st_map
        ld      a,(W2)
        pop     hl
        cp      e
        ret     z
        jr      st_fail

; Commit page HL in MMU register B (byte 0), by port: byte 0, then byte 1.
; B and C changed.
st_map: ld      c,SYSPAGE
        out     (c),l
        inc     b
        out     (c),h
        ret

; Windows 2-6 back to SRAM pages 0-4, read and write (D kept)
st_restore:
        ld      hl,0
        ld      b,MMU2_0
.next:  call    st_map
        inc     l
        inc     b
        ld      a,b
        cp      MMU7_0
        jr      nz,.next
        ret

; A check failed: D is its number
st_fail:
        ld      sp,ix
        call    st_restore
        ld      a,d
        or      a
        ret

; RST 38h from check 4C: HL = the address after the fetch, back to the caller
st_rst38:
        pop     hl
        ret

; MMU0_0 ... MMU7W_1 after reset (spec 2, section 9.4)
st_reset:
        db      0xFC, 3, 0xFD, 3, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0
        db      0xFC, 3, 0xFD, 3, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0

; Pages that read 0xFF: NONE and reserved ones (spec 2, section 9.3)
st_ffpages:
        dw      PG_NONE, 0x200, 0x2A5, 0x3F7, 0x3F9, 0x3FA, 0xFFFF

; Register page offsets with no unit yet, or reserved, in window 3: 0xFF.
; Only read: KEYROW, the rest of the custom block and the palettes get units
; later, and
; this list shrinks as they come.
st_ffoffs:
        dw      W3+0x0F, W3+0xFF, W3+REGS_KEYROW, W3+REGS_KEYROW+7, W3+0x108, W3+0xFFF
        dw      W3+REGS_CUSTOM+0x00F, W3+REGS_CUSTOM+0x3FF, W3+REGS_PALETTE, W3+0x1FFF, 0xFFFF
