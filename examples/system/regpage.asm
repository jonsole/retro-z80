; Example 1-3 (docs/guide/system.md): the registers as memory.
; Moves the stack out of window 7, maps the register page (MMU page 0x3F8)
; there, and then works on registers with ordinary loads: it reads SYSID,
; sets the background colour to orange (blue and green first, red last),
; and waits two seconds, 100 frames of VIDSTAT.VBLANK. Then window 7 gets
; SRAM page 7 back, through the register page itself, and JP 0x0040 (the
; ROM's EXIT) ends the program.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h function: print A as two hex digits
EXIT    equ     0x0040                  ; the ROM's EXIT: back to the monitor, whatever SP holds
PG_REGS equ     0x3F8                   ; the register page

REGS    equ     0xE000                  ; the register page, in window 7
SREG    equ     REGS+REGS_SYSTEM        ; 0xE000: system register r at SREG + r
CREG    equ     REGS+REGS_CUSTOM        ; 0xF000: custom offset k at CREG + k

start:  ld      sp,0xE000               ; the stack below window 7, at the top of window 6
        ld      hl,PG_REGS
        ld      bc,MMU7_0_P             ; the first mapping needs ports
        out     (c),l
        inc     b
        out     (c),h                   ; from here, 0xE000-0xFFFF are the registers

        ld      hl,s_id
        rst     0x18                    ; PUTS
        ld      a,(SREG+SYSID)          ; a register read with LD
        rst     0x28
        db      PUTHEX

        ld      hl,0x8000               ; BGCOLOR: blue 0x00, green 0x80 ...
        ld      (CREG+BGCOLOR),hl       ; (held for the red byte)
        ld      a,0xFF
        ld      (CREG+BGCOLOR+2),a      ; ... red 0xFF: the colour changes, whole

        ld      b,100                   ; 100 frames: 2 seconds
.frame: ld      a,VIDSTAT_VBLANK_M
        ld      (CREG+VIDSTAT),a        ; a sticky flag: writing 1 clears it
.wait:  ld      a,(CREG+VIDSTAT)
        and     VIDSTAT_VBLANK_M        ; set again at the next frame's start
        jr      z,.wait
        djnz    .frame

        ld      hl,7
        ld      (SREG+MMU7),hl          ; window 7 back to SRAM page 7, in one instruction
        jp      EXIT

s_id:   db      13, 10, "SYSID through the register page: ", 0
