; The CP/M pieces that the ZEX tests need, for tb_zex.v. The image is loaded
; at 0x0000 before the .COM program goes in at 0x0100.
;
; 0x0000  reset enters the program; a later jump to 0 (warm boot) ends the run
; 0x0005  BDOS entry; the word at 0x0006 is the top of the TPA, used as the stack
; 0xFF00  BDOS: function 2 prints E, function 9 prints the string at DE up to
;         '$'. Characters go out on I/O port CONSOLE, where the testbench
;         takes them: 0x00 for tb_zex.v (the bare core). tb_zexsys.v (the
;         whole system) builds it with -DCONSOLE=0x01, a reserved port that
;         the machine ignores (spec 1, section 6.1); port 0x00 there is the
;         system block.

        IFNDEF  CONSOLE
        DEFINE  CONSOLE 0x00
        ENDIF

        org     0x0000
        jp      0x0100
        db      0, 0
        jp      bdos

        ds      0xFF00 - $, 0  ; pad: --raw output starts at 0x0000
bdos:   ld      a, c
        cp      2
        jr      z, .f2
        cp      9
        ret     nz
.f9:    ld      a, (de)
        cp      '$'
        ret     z
        out     (CONSOLE), a
        inc     de
        jr      .f9
.f2:    ld      a, e
        out     (CONSOLE), a
        ret
