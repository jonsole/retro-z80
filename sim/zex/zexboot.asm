; Loader for tb_zexsys.v (ticket #7): runs in place of the boot ROM and starts
; a CP/M program that the testbench has put in SRAM pages 0-7, with page
; zero and the BDOS (cpm.asm) at physical 0x000000 and the program at
; 0x000100.
;
; At reset windows 0-1 are boot ROM and windows 2-7 SRAM pages 0-5 (spec 2,
; section 9.4). The loader maps window n to SRAM page n for n = 2-7, copies
; a trampoline to 0xFFE0 (page 7) and jumps to it; the trampoline maps
; windows 0 and 1 to pages 0 and 1, out from under the ROM, and jumps to
; 0x0100. The Z80 then sees a flat 64 KB of SRAM. Each window is set by its
; read page (MMUn_0, then MMUn_1 commits it), which also sets the write page.

        DEVICE  NOSLOT64K
        include "hw.inc"

TRAMP   equ     0xFFE0

        ORG     0x0000

reset:  di
        ld      c,0x00                  ; the system block's I/O page
        ld      d,7                     ; windows 7 down to 2
.win:   ld      a,d
        add     a,a
        add     a,MMU0_0
        ld      b,a                     ; B = MMUn_0
        ld      a,d
        out     (c),a                   ; page bits 7-0 = n (held)
        inc     b
        xor     a
        out     (c),a                   ; page bits 9-8 = 0: commit
        dec     d
        ld      a,d
        cp      2
        jr      nc,.win
        ld      hl,tramp
        ld      de,TRAMP
        ld      bc,tramp_end - tramp
        ldir
        jp      TRAMP

tramp:
        DISP    TRAMP
        ld      bc,MMU0_0_P             ; window 0 = page 0
        xor     a
        out     (c),a
        inc     b
        out     (c),a
        ld      bc,MMU1_0_P             ; window 1 = page 1
        inc     a
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        jp      0x0100
        ENT
tramp_end:
        ASSERT  TRAMP + (tramp_end - tramp) <= 0x10000
