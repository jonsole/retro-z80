; Assembles firmware/include/hw.inc with sjasmplus and checks names against values
; quoted in the specs (spec 3 section 8 and the unit specs), as independent literals.
; Run by tools/Makefile (make -C tools check).

        device none
        include "hw.inc"

        ; spec 3, section 8
        assert INTID = 0x0C
        assert SYSID = 0x70
        assert SYSID_P = 0x7000
        assert BGCOLOR = 0x004
        assert BGCOLOR_P = 0x0410
        assert SERDATA_PORT = 0x53
        assert KEMPSTON_PORT = 0x1F
        assert ULA_PORT = 0xFE
        assert SYSPAGE = 0x00
        assert CUSTPAGE = 0x10
        assert REGS_SYSTEM = 0x0000
        assert REGS_KEYROW = 0x0100
        assert REGS_CUSTOM = 0x1000
        assert REGS_PALETTE = 0x1400
        assert REGS_PAL_SPAN = 0x300

        ; byte names (spec 3, section 8)
        assert TIME0 = 0x20 && TIME3 = 0x23 && TIME3_P = 0x2300
        assert SDCON1 = 0x59 && SPRDMA1 = 0x121 && WDTIME1 = 0x4A
        assert TMR0_COUNT0 = 0x2D && TMR2_COUNT1 = 0x3E
        assert SPR0_PT0 = 0x010 && L1_BPL0PT2 = 0x0C6 && DMX2_CHDESC0 = 0x1E0
        assert MMU0_0 = 0x80 && MMU0_1 = 0x81 && MMU0W_0 = 0x90 && MMU0W_1 = 0x91
        assert MMU7_1_P = 0x8F00 && MMU6 = 0x8C
        assert KEYMAP6 = 0x16 && SERSTAT1 = 0x52 && SPRCOLL3 = 0x127
        assert NMISAV0 = 0x7D && NMISAVW0 = 0x7E && NMISAVHI = 0x7F

        ; arrays (specs 4, 5, 9, 14)
        assert L0 = 0x090 && L1 = 0x0B0 && L2 = 0x0D0 && L_SPAN = 0x20 && L_NUM = 3
        assert L_BPL0PT = 0x14 && L1_BPL0PT = 0x0C4 && L1_BPL0PT_P = 0xC410
        assert SPR0 = 0x010 && SPR7 = 0x080 && SPR_H = 0x3 && SPR_STEP = 0xC
        assert SPR_CTL_PAL_B = 4 && SPR_STEP_YSTEP_B = 16
        assert TMR_NUM = 4 && TMR_SPAN = 8 && TMR2_COUNT = 0x3D
        assert DMX0 = 0x140 && DMX3 = 0x200 && DMX_CHCTRL = 0x24
        assert DMX2_CHCTRL_P = 0xE411 && DMX3_CHCTRL_P = 0x2412
        assert DMXINT_P = 0x3012 && DMXINTEN_P = 0x3412

        ; widths
        assert BGCOLOR_N = 3 && SPR0_H_N = 4 && TIME_N = 4 && INTCON_N = 1 && MMU3_N = 2

        ; ports of the custom pages (spec 3, section 5.1)
        assert COPCON_P = 0x0011 && COPR7_P = 0x1F11 && ATCTL_P = 0x3011
        assert BEAMPOS_P = 0xF010 && PRIO = 0x003
        assert SEQCON = 0x300 && SEQCON_P = 0x0013 && SEQLC_P = 0x0113 && SEQPT0_P = 0x0813  ; spec 17
        assert SEQSKIPL = 0x307 && SEQ_END = 0x7FF && SEQ_ENTRY = 16

        ; fields and interrupts (specs 8 and 9)
        assert INTENA_SETCLR_M = 0x80
        assert INT_VBLANK = 0 && INT_TIMER0 = 11 && INT_SOFT = 18 && INT_NONE = 23
        assert INTB_TIMER0 = 4 && INTR_TIMER0 = 1 && INTB_SOFT = 4 && INTR_SOFT = 2
        assert SDCON_CLKDIV_M = 0xFF00 && SDCON_AUTO_M = 0x80
        assert CPUSPEED_SPECTRUM_M = 0x08 && DMACON_SETCLR_M = 0x80
        assert SYSRESET_MAGIC = 0xA5 && WDKICK_MAGIC = 0x5A
        assert VID_X0 = 144 && VID_Y0 = 49 && BEAM_W = 864 && BEAM_H = 625

        ; the names work in instructions, as in spec 8's example
        org 0
        ld   bc,INTENA0_P+(INTR_VBLANK<<8)
        ld   a,INTENA_SETCLR_M|(1<<INTB_VBLANK)
        out  (c),a
        ld   bc,SPR0_PT_P
        out  (c),l
        ld   a,INTID
        in   a,(SYSPAGE)
        ld   hl,(0xE000+REGS_CUSTOM+BGCOLOR)
