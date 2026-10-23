; Smoke test for the tool chain: sjasmplus assembles this, tools/bin2hex.py
; packs it into little-endian words, and tb_smoke.v checks the words.

        DEVICE  NOSLOT64K
        ORG     0x0000

start:  di
        ld      sp,0x0000
        jp      start
        db      "Z80"
