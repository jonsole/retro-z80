#!/usr/bin/env python3
"""Reference model of the video (spec 4) for the layers built so far (L0, a
chunky bitmap or a tile map; tickets #13 and #14) and the sprites (spec 5;
ticket #31): replays every write the testbench logged, renders a frame and
compares it pixel by pixel with the frame the simulation sent.

    vmodel.py DIR RAM.hex FRAME [OUT.png]

DIR holds vlog.txt (every write to the video unit: frame, beam line, beam
pixel, beam running, bus address, data), frame.ppm (beam frame FRAME, as
sent) and vend.txt (VIDSTAT and SPRCOLL at the end). RAM.hex is the SRAM's contents
($readmemh words; the picture data does not change during the test).

The model is written from the spec, not from the RTL:
  - registers are bytes, written directly (spec 3, rule 2); a colour
    changes on its red byte, blue and green waiting in the CPU's colour
    assembly buffer, shared by BGCOLOR, PALDAT and the register page
    palettes (rule 7; spec 4, 6.5)
  - line settings (CTRL, WINX, WINY, SCROLLX; DMACON) written in beam line
    L act from line L + 1 (spec 4, 5.6); PRIO and BGCOLOR act from the
    picture of the line they are written in if written before its beam
    pixel 144, else from the next; a write too close to either moment is an
    error of the test, not of the design
  - BPL0PT and BPLSTRIDE are live; the test writes them only on lines the
    layer does not fetch, so a write in line L is line L + 1's start
  - the pointer: each line's start + BPLSTRIDE after the last copy of a
    source line, back to the start after the others, wrapping in its
    2^(n+9)-byte block (CTRL2.WRAP); windows clamped to the picture; each
    source pixel shown HSCALE times; SCROLLX bits 3-0 source pixels skipped;
    the vertical copies counted from the window's first line (spec 4, 4.3-4.7)
  - SRAM bytes little-endian; chunky pixels leftmost in the high bits
  - tile maps (spec 4, 4.5): map line (SCROLLY + n) mod (8 x map height),
    n the source line from the window's top; map pixel (SCROLLX + i) mod
    (8 x map width), i the source pixel across the window; entries at
    MAPPT + (row x width + column) x 2; tile t's row at PATPT + 8dt + d x
    row, YFLIP picking row 7 - y, XFLIP pixel 7 - x; PAL added to PALOFS
    (mod 16) below 8 bits; MAPW and MAPH 3 as 128
  - sprites (spec 5, sections 3 and 4): every register write acts from the
    next line (the test keeps them away from the line's end and start); a
    CTL write starts a sprite, the vertical blank (beam line 0) stops them
    all; at the start of each line a running sprite whose window covers it
    shows, its image line moved on by YSTEP (k lines of wf words, not on
    its first line or after a PT write); screen pixel i of the window shows
    source pixel floor(i x XSTEP / 2048); the image is bytes at rising
    addresses, the first pixel in the high bits; value 0 transparent; a
    sprite started with its DMA off (SPRDMA) shows nothing; pixels before
    beam pixel 144 or line 49 are not shown
  - priority (spec 4, 4.8): from the back, BGCOLOR, DEPTH 3 sprites, PRIO's
    BACK, DEPTH 2, MIDDLE, DEPTH 1, FRONT, PRI tile pixels, DEPTH 0; among
    sprites of a DEPTH the lower number in front; sprites take SPRPALETTE,
    or PALETTE0 with VIDCON.SHAREPAL
  - collisions (spec 5, 3.6): over the frame's picture, sprite with sprite
    and sprite with an opaque L0 pixel, whatever the depth; SPRCOLL at the
    end is the frame's (the test starts sprites only in the frame checked)
Exits 1 on any difference, an ambiguous write, OVERRUN or SPRUNDER.
"""
import sys

X0, Y0 = 144, 49
W, H = 720, 576
HTOT, VTOT = 864, 625


def spectrum(e):
    l = 0xFF if e & 8 else 0xD7
    return ((l if e & 2 else 0) << 16) | ((l if e & 4 else 0) << 8) | (l if e & 1 else 0)


def load_ram(path):
    ram, a = {}, 0
    for line in open(path):
        line = line.split("//")[0].strip()          # $writememh writes address comments
        if not line:
            continue
        if "x" in line.lower():                     # never written: X in the SRAM model
            a += 1
            continue
        if line[0] == "@":
            a = int(line[1:], 16)
        else:
            v = int(line, 16)
            ram[2 * a] = v & 0xFF                  # little-endian: the even byte is the low half
            ram[2 * a + 1] = v >> 8
            a += 1
    return ram


def load_ppm(path):
    t = open(path).read().split()
    assert t[0] == "P3"
    w, h = int(t[1]), int(t[2])
    v = list(map(int, t[4:]))
    return w, h, [(v[i] << 16) | (v[i + 1] << 8) | v[i + 2] for i in range(0, len(v), 3)]


class Fail(Exception):
    pass


def main():
    d, ramfile, G = sys.argv[1], sys.argv[2], int(sys.argv[3])
    ram = load_ram(ramfile)
    byte = lambda a: ram.get(a & 0x3FFFFF, 0)
    errors = []

    # ---- replay the writes into timed effects
    pal = [spectrum(i % 256) if i % 256 < 16 else 0 for i in range(1024)]   # section 7.4
    cab = [0, 0]                       # the CPU's colour assembly buffer: blue, green
    palidx, pcnt = 0, 0
    vidcon_w = 0
    line_fx = []                       # (frame, line, register offset, value): line settings, in order
    pic_fx = []                        # (frame, line, "prio" / "bg", value)
    live = []                          # (frame, line, offset, value, write line): pointer and stride
    spr_ev = []                        # (frame, line, offset, value): sprite registers, SPRDMA, from that line
    for n, row in enumerate(open(d + "/vlog.txt")):
        f, bv, bh, on, a, v = row.split()
        f, bv, bh, on, a, v = int(f), int(bv), int(bh), int(on), int(a, 16), int(v, 16)
        if not on:
            f, bv, bh = -1, 0, 400                  # before the beam started: before everything
        nxt = (f, bv + 1) if bv + 1 < VTOT else (f + 1, 0)
        o = a - 0x1000
        if a >= 0x1400:                             # the palettes in the register page (spec 4, 6.5)
            q = a - 0x1400
            p, r = q // 0x300, q % 0x300
            if r % 3 < 2:
                cab[r % 3] = v
            else:
                pal[p * 256 + r // 3] = (v << 16) | (cab[1] << 8) | cab[0]
            if f >= G:
                errors.append("a palette write in the frame checked")
        elif o == 0x00B:                            # PALDAT
            if pcnt < 2:
                cab[pcnt] = v
                pcnt += 1
            else:
                pal[palidx] = (v << 16) | (cab[1] << 8) | cab[0]
                palidx = (palidx + 1) & 0x3FF
                pcnt = 0
            if f >= G:
                errors.append("a palette write in the frame checked")
        elif o in (0x009, 0x00A):                   # PALIDX
            palidx = (palidx & 0x300) | v if o == 0x009 else (palidx & 0xFF) | ((v & 3) << 8)
            pcnt = 0
        elif o in (0x004, 0x005, 0x006, 0x003):     # BGCOLOR, PRIO: at the start of a line's picture
            if 141 <= bh <= 146:
                errors.append("write %d (%03x) at beam pixel %d: too close to the picture's start" % (n, o, bh))
            at = (f, bv) if bh < 141 else nxt
            if o == 0x003:
                pic_fx.append(at + ("prio", v & 0x3F))
            elif o < 0x006:
                cab[o - 0x004] = v
            else:
                pic_fx.append(at + ("bg", (v << 16) | (cab[1] << 8) | cab[0]))
        elif 0x010 <= o <= 0x08F or o in (0x120, 0x121):   # sprites, SPRDMA: from the next line
            if bh <= 20 or bh >= 815:
                errors.append("write %d (%03x) at beam pixel %d: too close to the line's end or start" % (n, o, bh))
            spr_ev.append(nxt + (o, v))
        elif o == 0x000:                            # VIDCON: at once
            if f >= 0:
                errors.append("a VIDCON write while the beam runs")
            vidcon_w = v
        elif o == 0x00C or 0x090 <= o <= 0x0AF:     # DMACON and L0: from the next line
            if bh <= 4 or bh >= 862:
                errors.append("write %d (%03x) at beam pixel %d: too close to the line's start" % (n, o, bh))
            if o in (0x0A0, 0x0A1, 0x0A4, 0x0A5, 0x0A6):
                live.append(nxt + (o, v, (f, bv)))
            else:
                line_fx.append(nxt + (o, v))
    if errors:
        raise Fail(errors)

    # ---- line by line, from the beam's start to the frame checked
    R = {k: 0 for k in range(0x090, 0x0B0)}       # L0's registers, reset values (spec 4, 6.3)
    R.update({0x094: 864 & 0xFF, 0x095: 864 >> 8, 0x096: 144, 0x097: 0, 0x098: 625 & 0xFF, 0x099: 625 >> 8,
              0x09A: 49, 0x09B: 0})
    dmacon, prio, bg = 0, 0x24, 0
    vidcon = vidcon_w                  # written only before the beam starts
    ptr, stride = 0, 0
    vsub = 0
    srcn = 0                                         # the window's source line (tiles)
    li = pi = vi = 0
    line_fx.sort(key=lambda e: (e[0], e[1]))       # stable: the order written within a line
    pic_fx.sort(key=lambda e: (e[0], e[1]))
    live.sort(key=lambda e: (e[0], e[1]))
    img = [None] * (W * H)
    nlay = 0                                         # pixels L0 showed
    tox = lambda v: 0 if v < X0 else W if v > HTOT else v - X0
    toy = lambda v: 0 if v < Y0 else H if v > VTOT else v - Y0
    fetched = {}                                     # (frame, line): the layer fetched on it
    share = (vidcon >> 5) & 1
    # The sprites: their registers as written (16 bytes each), and each one's state
    SR = [[0] * 16 for _ in range(8)]
    lst = [0] * 8
    run, pend, fed, syf = [False] * 8, [False] * 8, [False] * 8, [0] * 8
    sprdma, sprdma_w = 0xFF, 0
    si = 0
    spr_ev.sort(key=lambda e: (e[0], e[1]))
    lim = lambda st: 0x800 if st == 0 else max(0x80, min(0x8000, st))
    coll = 0
    nspr = 0                                         # sprite pixels shown

    def sprites_line(f, L):
        """The sprites' events from line L of frame f, the vertical blank, and
        each running sprite on line L: its pixels as {x: [(n, idx, depth)]}"""
        nonlocal si, sprdma, sprdma_w
        while si < len(spr_ev) and spr_ev[si][:2] <= (f, L):
            o, v = spr_ev[si][2:]
            si += 1
            if o == 0x120:
                sprdma_w = v
            elif o == 0x121:
                sprdma = (sprdma | sprdma_w) if v & 0x80 else (sprdma & ~sprdma_w & 0xFF)
            else:
                n, k = (o - 0x010) >> 4, (o - 0x010) & 15
                SR[n][k] = v
                if k <= 2:                          # PT: the next image line starts here
                    sh = 8 * k
                    lst[n] = (lst[n] & ~(0xFF << sh)) | ((v & (0xFE, 0xFF, 0x3F)[k]) << sh)
                    pend[n] = False
                if k == 11:                         # CTL: starts it
                    run[n], pend[n], syf[n] = True, False, 0
                    fed[n] = bool((sprdma >> n) & 1 and dmacon & 0x44 == 0x44)
        if L == 0:
            for n in range(8):
                run[n] = False                      # the vertical blank stops every sprite
        line = {}
        for n in range(8):
            if not run[n]:
                continue
            r = SR[n]
            hs = r[3] | ((r[4] & 7) << 8)
            he = r[5] | ((r[6] & 7) << 8)
            vs = r[7] | ((r[8] & 7) << 8)
            ve = min(r[9] | ((r[10] & 7) << 8), 625)
            b = r[11] & 3
            lb = (2 if b == 3 else b) + 1
            bpp = 1 << lb
            depth, spal = (r[11] >> 2) & 3, r[11] >> 4
            xst = lim(r[12] | (r[13] << 8))
            yst = lim(r[14] | (r[15] << 8))
            hs_c = min(hs, 864)
            xe = max(min(he, 864), hs_c)
            srcf = -(-(he - hs) * xst // 2048) if he > hs else 0
            srcs = -(-(xe - hs_c) * xst // 2048)
            wf = (srcf * bpp + 15) // 16
            wv = min((srcs * bpp + 15) // 16, wf) if srcs else 0
            if wv == 0 or not (vs <= L < ve):
                continue
            if fed[n] and not ((sprdma >> n) & 1 and dmacon & 0x44 == 0x44):
                # off part way down, it would show its FIFO's last words (spec 5, 4.4): the test never does it
                raise Fail(["sprite %d's DMA off on a line it shows (line %d): not modelled" % (n, L)])
            if pend[n]:
                sm = syf[n] + (yst & 0x7FF)
                syf[n] = sm & 0x7FF
                lst[n] = (lst[n] + ((yst >> 11) + (sm >> 11)) * 2 * wf) & 0x3FFFFF
            else:
                syf[n] = 0
            pend[n] = True
            if f != G or L < Y0 or not fed[n]:
                continue
            for x in range(max(hs_c, X0), xe):
                i = ((x - hs_c) * xst) >> 11
                bo = i * bpp
                v = (byte(lst[n] + (bo >> 3)) >> (8 - bpp - (bo & 7))) & ((1 << bpp) - 1)
                if v:
                    line.setdefault(x - X0, []).append((n, v if bpp == 8 else (spal << 4) | v, depth))
        return line

    def take(f, L):
        """The effects that act from line L of frame f."""
        nonlocal li, vi, pi, dmacon, ptr, stride, prio, bg
        while li < len(line_fx) and line_fx[li][:2] <= (f, L):
            o, v = line_fx[li][2:]
            li += 1
            if o == 0x00C:                           # DMACON: set/clear (spec 3, rule 12)
                dmacon = (dmacon | (v & 0x7E)) if v & 0x80 else (dmacon & ~v)
            else:
                R[o] = v
        while vi < len(live) and live[vi][:2] <= (f, L):
            o, v, wl = live[vi][2:]
            vi += 1
            if fetched.get(wl):
                raise Fail(["pointer or stride written in line %s, where the layer fetches" % (wl,)])
            if o >= 0x0A4:                           # BPL0PT: bits 21-1
                sh = 8 * (o - 0x0A4)
                ptr = (ptr & ~(0xFF << sh)) | ((v & (0xFE, 0xFF, 0x3F)[sh // 8]) << sh)
            else:                                    # BPLSTRIDE: even
                sh = 8 * (o - 0x0A0)
                stride = (stride & ~(0xFF << sh)) | ((v & (0xFE, 0xFF)[sh // 8]) << sh)
        while pi < len(pic_fx) and pic_fx[pi][:2] <= (f, L):
            if pic_fx[pi][2] == "prio":
                prio = pic_fx[pi][3]
            else:
                bg = pic_fx[pi][3]
            pi += 1

    for f in range(0, G + 1):
        for L in range(VTOT):
            take(f, L)
            sline = sprites_line(f, L)
            if f == 0 and L < 50:
                continue                             # the beam starts at beam line 49, with no setup
            # The line's settings
            c0, c1, c2 = R[0x090], R[0x091], R[0x092]
            en, lb, transp, mode, hs = c0 & 1, (c0 >> 2) & 3, (c0 >> 4) & 1, (c0 >> 5) & 1, c0 >> 6
            vs, palofs, wrap = c1 & 3, c1 >> 4, c2 >> 4
            xe = R[0x094] | ((R[0x095] & 7) << 8)
            xs = R[0x096] | ((R[0x097] & 7) << 8)
            ye = R[0x098] | ((R[0x099] & 7) << 8)
            ys = R[0x09A] | ((R[0x09B] & 7) << 8)
            sx = R[0x09C] & 15
            sxt = R[0x09C] | ((R[0x09D] & 3) << 8)
            syt = R[0x09E] | ((R[0x09F] & 3) << 8)
            mw = 32 << min(R[0x093] & 3, 2)
            mh = 32 << min((R[0x093] >> 2) & 3, 2)
            mappt = (R[0x0A8] & 0xFE) | (R[0x0A9] << 8) | ((R[0x0AA] & 0x3F) << 16)
            patpt = (R[0x0AC] & 0xFE) | (R[0x0AD] << 8) | ((R[0x0AE] & 0x3F) << 16)
            xs_c, ys_c, ye_c = tox(xs), toy(ys), toy(ye)
            xe_c = max(tox(xe), xs_c)
            nl = (L - Y0) % VTOT                     # the picture line (576-624: the vertical blank)
            vmax = (1 << vs) - 1
            inwin = ys_c <= nl < ye_c
            vs_n = 0 if (nl == ys_c or vsub == vmax) else vsub + 1
            if inwin:
                srcn = 0 if nl == ys_c else srcn + 1 if vs_n == 0 else srcn
                vsub = vs_n
            fetch = bool(dmacon & 0x40 and dmacon & 0x20)
            act = en and nl < H and inwin and fetch
            fetched[(f, L)] = act
            bpp = 1 << lb
            m = (1 << (wrap + 9)) - 1 if wrap else 0x3FFFFF
            wadd = lambda a, dd: (a & ~m) | ((a + dd) & m)
            srcpix = ((xe_c - xs_c) + (1 << hs) - 1) >> hs
            groups = (sx + srcpix + 15) >> 4
            if f == G and nl < H:
                y = nl
                shown = 0 in ((prio >> 4) & 3, (prio >> 2) & 3, prio & 3) and not vidcon & 4
                for x in range(W):
                    col = bg
                    lop, lidx, lpri = False, 0, False
                    if act and xs_c <= x < xe_c and mode:
                        ty = (syt + srcn) % (8 * mh)
                        xm = (sxt + ((x - xs_c) >> hs)) % (8 * mw)
                        ea = mappt + ((ty >> 3) * mw + (xm >> 3)) * 2
                        e = byte(ea) | (byte(ea + 1) << 8)
                        t, tpal, xf, yf = e & 0x1FF, (e >> 9) & 15, (e >> 13) & 1, (e >> 14) & 1
                        row = (ty & 7) ^ (7 if yf else 0)
                        bo = ((xm & 7) ^ (7 if xf else 0)) * bpp
                        b8 = byte(patpt + t * 8 * bpp + row * bpp + (bo >> 3))
                        v = (b8 >> (8 - bpp - (bo & 7))) & ((1 << bpp) - 1)
                        if not (transp and v == 0):
                            lop, lidx, lpri = True, v if bpp == 8 else ((palofs + tpal) % 16) * 16 + v, bool(e >> 15)
                    elif act and xs_c <= x < xe_c:
                        bo = (sx + ((x - xs_c) >> hs)) * bpp
                        a = wadd(ptr, 2 * (bo >> 4))
                        wv = (byte(a) << 8) | byte(a + 1)
                        v = (wv >> (16 - bpp - (bo & 15))) & ((1 << bpp) - 1)
                        if not (transp and v == 0):
                            lop, lidx = True, v if bpp == 8 else palofs * 16 + v
                    here = sline.get(x, [])
                    if len(here) > 1:
                        for sn, _, _ in here:
                            coll |= 1 << sn
                    if lop:
                        for sn, _, _ in here:
                            coll |= 1 << (8 + sn)
                    # back to front (spec 4, 4.8): DEPTH 3, BACK, DEPTH 2, MIDDLE, DEPTH 1, FRONT, PRI, DEPTH 0
                    if not vidcon & 4:
                        win = None
                        for pl in (3, 2, 1, 0):
                            for sn, sidx, sdep in reversed(here):
                                if sdep == pl:
                                    col, win = pal[(0 if share else 3) * 256 + sidx], "S"
                            if pl > 0 and lop and ((prio >> (2 * (pl - 1))) & 3) == 0:
                                col, win = pal[lidx], "L"
                            if pl == 1 and lop and lpri and shown:
                                col, win = pal[lidx], "L"
                        nlay += win == "L"
                        nspr += win == "S"
                    img[y * W + x] = col
            if act and not mode and groups > 0:
                sval = stride - 0x10000 if stride & 0x8000 else stride
                ptr = wadd(ptr, sval if vs_n == vmax else 0)

    fw, fh, got = load_ppm(d + "/frame.ppm")
    diffs = 0
    if (fw, fh) != (W, H):
        print("vmodel: frame is %dx%d" % (fw, fh))
        diffs += 1
    else:
        for i in range(W * H):
            if got[i] != img[i]:
                if diffs < 10:
                    print("vmodel: pixel (%d, %d) is %06x, expected %06x" % (i % W, i // W, got[i], img[i]))
                diffs += 1
    vend = dict(l.split() for l in open(d + "/vend.txt"))
    if (int(vend["vidstat"]) >> 4) & 15:
        print("vmodel: OVERRUN or SPRUNDER set: VIDSTAT %02x" % int(vend["vidstat"]))
        diffs += 1
    if spr_ev and int(vend.get("sprcoll", 0)) != coll:
        print("vmodel: SPRCOLL is %08x, expected %08x" % (int(vend.get("sprcoll", 0)), coll))
        diffs += 1
    if spr_ev and nspr == 0:
        print("vmodel: no sprite shows in the frame")
        diffs += 1
    if len(sys.argv) > 4:
        try:
            from PIL import Image
            im = Image.new("RGB", (W, H))
            im.putdata([((c >> 16) & 255, (c >> 8) & 255, c & 255) for c in img])
            im.save(sys.argv[4])
        except ImportError:
            pass
    if nlay == 0:
        print("vmodel: L0 shows nothing in the frame")
        diffs += 1
    print("vmodel: %d differences in %d x %d, beam frame %d; %d pixels from L0, %d with sprites; SPRCOLL %08x"
          % (diffs, W, H, G, nlay, nspr, coll))
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        for m in e.args[0][:10]:
            print("vmodel: " + m)
        sys.exit(1)
