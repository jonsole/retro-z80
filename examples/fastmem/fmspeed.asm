; The fast-memory experiment's measurement (issue #91; fpga/ks2/README.md,
; "The fast-memory experiment"). Runs on both cut-down KS2 builds, 12.5 ns
; (build.sh --fastmem) and 20 ns (--fastmem --slow), so the two can be
; compared:
;
;   - the DMA engine fills 512 KB and copies 512 KB, each timed with TIME
;     (microseconds, spec 9) and printed in MB/s;
;   - after each, the Z80 reads all 512 KB back and checks it: the fill's
;     4-byte value, and the copy against the source, 256 K words from a
;     16-bit xorshift (so the SRAM is checked while it runs at full load);
;   - LDIR of 8 KB is timed too: the Z80 never waits for memory, so it must
;     take the same time on both builds;
;   - each is done twice, with the examples' 360 x 288 8 bpp screen showing
;     (L0 at 2x, examples/blitter/screen.inc), and with the layers' fetches
;     off (DMACON.BPLEN clear); VIDSTAT's OVERRUN bits say whether the
;     display ever ran short.
;
; Each job starts on the first visible line of a frame, as the guide's
; Example 6-8 (examples/blitter/speed.asm) does. Memory, physical: the
; screen at 0x040000 (screen.inc), the source at 0x080000-0x0FFFFF, the
; destination at 0x100000-0x17FFFF: free in the program map on a 2 MB
; board. Window 5 (0xA000) is used to reach them and is put back at the end.
;
;   sjasmplus --nologo -I firmware/include --raw=build/fmspeed.bin examples/fastmem/fmspeed.asm
;   python tools/rlink.py -p COM3 upload build/fmspeed.bin --load 8000 --term

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

SRC     equ     0x080000                ; physical
DST     equ     0x100000
        IFDEF SIM
SIZE    equ     0x004000                ; 16 KB in the testbench (sim/fastmem/fmsim.asm)
LDLEN   equ     0x0400
        ELSE
SIZE    equ     0x080000                ; 512 KB
LDLEN   equ     0x2000                  ; LDIR: 8 KB
        ENDIF
SRCPG   equ     SRC >> 13               ; SRAM pages (8 KB)
DSTPG   equ     DST >> 13
NPG     equ     SIZE >> 13              ; 64
WIN5    equ     0xA000
FILLV   equ     0x3CC35AA5              ; the fill value: bytes A5 5A C3 3C, by address mod 4
OVER_M  equ     VIDSTAT_OVERRUNA_M | VIDSTAT_OVERRUN0_M | VIDSTAT_OVERRUN1_M | VIDSTAT_OVERRUN2_M

start:  jr      main
errs:   dw      0                       ; words read back wrong (at 0x8002, for the testbench)

main:   ld      hl,s_make
        rst     18h                     ; PUTS
        call    mksrc                   ; the source: 512 KB of xorshift words

        ld      a,BPP8
        ld      hl,360
        call    scr_on                  ; the examples' screen, DMAEN, BPLEN and BLTEN set
        IFNDEF SIM
        ld      hl,clearjob
        call    run2                    ; the screen dark blue
        ENDIF
        ld      bc,VIDSTAT_P
        ld      a,OVER_M
        out     (c),a                   ; W1C: the OVERRUN bits clear
        ld      ix,res                  ; the screen on
        call    pass
        ld      bc,DMACON_P
        ld      a,DMACON_BPLEN_M        ; SETCLR 0: the layers' fetches off
        out     (c),a
        ld      ix,res + 2              ; the screen off
        call    pass
        ld      bc,VIDSTAT_P
        in      a,(c)
        and     OVER_M
        ld      (vstat),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M | DMACON_BPLEN_M
        out     (c),a
        call    scr_off
        ld      hl,5                    ; window 5 back to the program map
        call    map5

        ; ---- the results
        ld      hl,s_head
        rst     18h
        ld      hl,s_fill
        ld      ix,res
        call    line
        ld      hl,s_copy
        ld      ix,res + 4
        call    line
        ld      hl,s_ldir
        rst     18h
        ld      hl,(res + 8)
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,s_sep
        rst     18h
        ld      hl,(res + 10)
        rst     28h
        db      0x08
        ld      hl,s_us
        rst     18h
        ld      hl,s_check
        rst     18h
        ld      hl,(errs)
        rst     28h
        db      0x08
        ld      hl,s_wrong
        rst     18h
        ld      a,(vstat)
        or      a
        ld      hl,s_vok
        jr      z,.vs
        ld      hl,s_vbad
.vs:    rst     18h
        ret                             ; back to the monitor

; line: print "<HL> t us (m.m MB/s) / t us (m.m MB/s)" for the results at IX
line:   rst     18h
        ld      l,(ix+0)
        ld      h,(ix+1)
        call    tmbs
        ld      hl,s_sep
        rst     18h
        ld      l,(ix+2)
        ld      h,(ix+3)
        call    tmbs
        ld      hl,s_crlf
        rst     18h
        ret

; tmbs: print HL us and the speed of 512 KB in it
tmbs:   push    hl
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,s_us1
        rst     18h
        pop     hl
        push    ix
        call    mbs10                   ; MB/s x 10
        pop     ix
        call    div10
        push    af
        rst     28h
        db      0x08
        ld      a,'.'
        rst     08h                     ; PUTC
        pop     af
        add     a,'0'
        rst     08h
        ld      hl,s_mbs
        rst     18h
        ret

; pass: fill, check, copy, check and LDIR, timed; the times go to IX + 0
; (fill), IX + 4 (copy) and IX + 8 (LDIR)
pass:   ld      hl,filljob
        call    time
        ld      (ix+0),l
        ld      (ix+1),h
        call    chkfill
        ld      hl,copyjob
        call    time
        ld      (ix+4),l
        ld      (ix+5),h
        call    chkcopy
        ld      hl,0                    ; LDIR
        call    time
        ld      (ix+8),l
        ld      (ix+9),h
        ret

; time: run the job at HL on channel 2 (HL = 0: LDIR of LDLEN, 0x2000 to
; 0x4000), starting on the first visible line of a frame; HL = the time in us
time:   push    hl
        call    wait2
        IFNDEF SIM
        call    frame                   ; the vertical blank has begun ...
        ld      bc,VIDSTAT_P
.vb:    in      a,(c)
        and     VIDSTAT_INVBLANK_M
        jr      nz,.vb                  ; ... and now it has ended
        ENDIF
        pop     hl
        ld      a,h
        or      l
        jr      nz,.job
        call    t0
        ld      hl,0x2000
        ld      de,0x4000
        ld      bc,LDLEN
        ldir
        jr      t1
.job:   call    load2
        call    t0
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a
        call    wait2
        ; fall into t1

; t1: HL = TIME now - the time t0 saved (the low 16 bits: up to 65 ms)
t1:     ld      bc,TIME0_P
        in      l,(c)                   ; reading TIME0 captures all 4 bytes
        inc     b
        in      h,(c)
        ld      de,(t0time)
        or      a
        sbc     hl,de
        ret

; t0: save TIME's low 16 bits
t0:     ld      bc,TIME0_P
        in      e,(c)
        inc     b
        in      d,(c)
        ld      (t0time),de
        ret

; map5: SRAM page HL into window 5 (read and write)
map5:   ld      bc,MMU5_0_P             ; byte 0 is held ...
        out     (c),l
        inc     b                       ; ... byte 1 commits, the write page too
        out     (c),h
        ret

; xs: the next 16-bit xorshift (7, 9, 8) of HL, in HL; A changed
xs:     ld      a,h
        rra
        ld      a,l
        rra
        xor     h
        ld      h,a
        ld      a,l
        rra
        ld      a,h
        rra
        xor     l
        ld      l,a
        xor     h
        ld      h,a
        ret

; mksrc: the source's 256 K words, the xorshift from 1, low byte first
mksrc:  ld      hl,1
        ld      (xstate),hl
        ld      hl,SRCPG
.page:  push    hl
        call    map5
        ld      hl,(xstate)
        ld      de,WIN5
        ld      bc,4096                 ; words in a page
.word:  call    xs
        ld      a,l
        ld      (de),a
        inc     de
        ld      a,h
        ld      (de),a
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.word
        ld      (xstate),hl
        pop     hl
        inc     hl
        ld      a,l
        cp      (SRCPG + NPG) & 0xFF
        jr      nz,.page
        ret

; chkcopy: the destination against the xorshift; mismatched words are
; added to errs
chkcopy:
        push    ix
        ld      hl,1
        ld      (xstate),hl
        ld      hl,DSTPG
.page:  push    hl
        call    map5
        ld      hl,(xstate)
        ld      de,WIN5
        ld      bc,4096
.word:  call    xs
        ld      a,(de)
        cp      l
        jr      nz,.bad1
        inc     de
        ld      a,(de)
        cp      h
        jr      nz,.bad2
.next:  inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.word
        ld      (xstate),hl
        pop     hl
        inc     hl
        ld      a,l
        cp      (DSTPG + NPG) & 0xFF
        jr      nz,.page
        pop     ix
        ret
.bad1:  inc     de
.bad2:  call    oneerr
        jr      .next

; chkfill: the destination against the fill value, a word at a time
chkfill:
        ld      hl,DSTPG
.page:  push    hl
        call    map5
        ld      hl,WIN5
        ld      bc,2048                 ; 4-byte groups in a page
.grp:   ld      de,FILLV & 0xFFFF
        call    chkw
        ld      de,FILLV >> 16
        call    chkw
        dec     bc
        ld      a,b
        or      c
        jr      nz,.grp
        pop     hl
        inc     hl
        ld      a,l
        cp      (DSTPG + NPG) & 0xFF
        jr      nz,.page
        ret
; chkw: the word at HL is DE? HL moves on 2
chkw:   ld      a,(hl)
        inc     hl
        cp      e
        jr      nz,.bad
        ld      a,(hl)
        cp      d
.bad:   inc     hl
        ret     z
        ; fall into oneerr

; oneerr: one more word wrong (errs stops at 65535)
oneerr: push    hl
        ld      hl,(errs)
        inc     hl
        ld      a,h
        or      l
        jr      z,.full
        ld      (errs),hl
.full:  pop     hl
        ret

; mbs10: HL = the time of SIZE bytes in us (not 0); HL = MB/s x 10,
; SIZE x 10 / HL by repeated subtraction (at most a few thousand)
mbs10:  ex      de,hl
        ld      hl,(SIZE * 10) & 0xFFFF
        ld      c,(SIZE * 10) >> 16     ; C:HL = SIZE x 10 (5,242,880 for 512 KB)
        ld      ix,0
.sub:   or      a
        sbc     hl,de
        ld      a,c
        sbc     a,0
        jr      c,.done
        ld      c,a
        inc     ix
        jr      .sub
.done:  push    ix
        pop     hl
        ret

; div10: HL = HL / 10, A = the remainder
div10:  ld      de,10
        ld      bc,0
.sub:   or      a
        sbc     hl,de
        jr      c,.done
        inc     bc
        jr      .sub
.done:  add     hl,de
        ld      a,l
        ld      h,b
        ld      l,c
        ret

t0time: dw      0
xstate: dw      1
vstat:  db      0
res:    ds      12                      ; fill on, off; copy on, off; LDIR on, off (us)

s_make: db      "Making 512 KB of test data...", 13, 10, 0
s_head: db      13, 10, "512 KB with the DMA engine, screen on / off:", 13, 10, 0
s_fill: db      "Fill: ", 0
s_copy: db      "Copy: ", 0
s_ldir: db      "LDIR 8 KB: ", 0
s_sep:  db      " / ", 0
s_us1:  db      " us (", 0
s_mbs:  db      " MB/s)", 0
s_us:   db      " us", 13, 10, 0
s_crlf: db      13, 10, 0
s_check: db     "SRAM check (2 x 2 x 512 KB read back): ", 0
s_wrong: db     " words wrong", 13, 10, 0
s_vok:  db      "Display: no overrun", 13, 10, 0
s_vbad: db      "Display: OVERRUN", 13, 10, 0

        align   4
filljob: db     OP_BLIT, BPP8|BCONST, 0, 0xCC   ; D = VALUE
        d24     0, 0, DST
        d24     SIZE                    ; one row
        dw      1, 0, 0, 0
        dd      FILLV
        d24     0
        db      0

copyjob: db     OP_BLIT, BPP8, 0, 0xCC          ; D = B
        d24     0, SRC, DST
        d24     SIZE
        dw      1, 0, 0, 0
        dd      0
        d24     0
        db      0

clearjob:
        db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN
        d24     360 * 288
        dw      1, 0, 0, 0
        dd      0x01010101              ; colour 1, blue
        d24     0
        db      0

        include "../blitter/screen.inc"
