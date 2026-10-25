; The CRC-32 table (zlib's CRC, the shared spec "Monitor and upload
; protocol", section 5.1), in ROM page 2, included by boot.asm: 1 KB as four
; rows of 256 bytes, each entry's bits 7-0, then 15-8, 23-16 and 31-24, so
; link.asm's crcbuf reaches byte k of entry n at crctab + 256 k + n. Made by
; the assembler at build time.

        ASSERT  low $ == 0
crctab:
        MACRO   CRCROW sh
n = 0
        DUP     256
c = n
        DUP     8
c = (c >>> 1) ^ ((c & 1) * 0xEDB88320)
        EDUP
        db      (c >>> sh) & 0xFF
n = n + 1
        EDUP
        ENDM
        CRCROW  0
        CRCROW  8
        CRCROW  16
        CRCROW  24
