import sys
out = sys.argv[1]
W, H = 760, 470
L = []; a = L.append
X = lambda p: 40 + 0.78 * p
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
# axis
a(f'  <text x="{X(432):g}" y="18" text-anchor="middle">one beam line: 864 pixels, 32 µs, 320 memory slots</text>')
for p in (0, 16, 144, 200, 344, 600, 864):
    a(f'  <line x1="{X(p):g}" y1="36" x2="{X(p):g}" y2="44" stroke="#777"/>')
    a(f'  <text x="{X(p):g}" y="33" text-anchor="middle" font-size="11" fill="#555">{p}</text>')
# beam row
y = 46
a(f'  <rect x="{X(0):g}" y="{y}" width="{X(144)-X(0):g}" height="26" fill="#d9d9d9" stroke="#333"/>')
a(f'  <rect x="{X(144):g}" y="{y}" width="{X(864)-X(144):g}" height="26" fill="#cfe2f3" stroke="#333"/>')
a(f'  <text x="{X(72):g}" y="{y+17}" text-anchor="middle" font-size="11">horizontal blank</text>')
a(f'  <text x="{X(504):g}" y="{y+17}" text-anchor="middle" font-size="11">picture</text>')
# markers
y = 280
def mark(p, t1, t2, dy, anchor='start'):
    a(f'  <line x1="{X(p):g}" y1="44" x2="{X(p):g}" y2="{y+dy-12}" stroke="#777" stroke-dasharray="4 3"/>')
    xt = X(p) + (4 if anchor == 'start' else -4)
    a(f'  <text x="{xt:g}" y="{y+dy}" text-anchor="{anchor}" font-size="11">{t1}</text>')
    if t2:
        a(f'  <text x="{xt:g}" y="{y+dy+14}" text-anchor="{anchor}" font-size="11">{t2}</text>')
mark(0, 'Pixel 0: each running sprite takes the line\'s settings (window, STEP, CTL);', 'whether the line is inside its window is decided by pixel 12', 20)
mark(16, 'Pixel 16: the earliest HSTART. The fetch needs a few pixels of lead', '', 64)
mark(844, 'Pixels 840–847: the next line\'s sizes are worked out', 'from H, V and STEP; later writes may miss it', 104, 'end')
# sprite 0: 32 px at 4 bpp, 8 words
y = 120
a(f'  <rect x="{X(0)-2:g}" y="{y-22}" width="440" height="18" fill="#ffffff"/>')
a(f'  <text x="{X(0):g}" y="{y-8}" font-weight="bold">Sprite 0: HSTART 344, 32 pixels at 4 bpp: 8 words a line</text>')
a(f'  <rect x="{X(12):g}" y="{y}" width="{X(40)-X(12):g}" height="14" fill="#f9cb9c" stroke="#333"/>')
a(f'  <text x="{X(40)+6:g}" y="{y+11}" font-size="11">all 8 words, early in the blank, as soon as cycles are free</text>')
a(f'  <rect x="{X(344):g}" y="{y+20}" width="{X(376)-X(344):g}" height="14" fill="#d5a6bd" stroke="#333"/>')
a(f'  <text x="{X(376)+6:g}" y="{y+31}" font-size="11">its pixels: 344–375</text>')
# sprite 1: 400 px at 8 bpp, 200 words
y = 200
a(f'  <rect x="{X(0)-2:g}" y="{y-22}" width="520" height="18" fill="#ffffff"/>')
a(f'  <text x="{X(0):g}" y="{y-8}" font-weight="bold">Sprite 1: HSTART 200, HSTOP 600, 400 pixels at 8 bpp: 200 words a line</text>')
a(f'  <rect x="{X(12):g}" y="{y}" width="{X(60)-X(12):g}" height="14" fill="#f9cb9c" stroke="#333"/>')
a(f'  <text x="{X(12):g}" y="{y+31}" font-size="11">fills the FIFO: 30 words</text>')
a(f'  <rect x="{X(200):g}" y="{y}" width="{X(540)-X(200):g}" height="14" fill="#f9cb9c" stroke="#333" stroke-dasharray="4 3"/>')
a(f'  <text x="{X(370):g}" y="{y+11}" text-anchor="middle" font-size="11">then a word per 2 pixels, 30 ahead</text>')
a(f'  <rect x="{X(200):g}" y="{y+20}" width="{X(600)-X(200):g}" height="14" fill="#d5a6bd" stroke="#333"/>')
a(f'  <text x="{X(400):g}" y="{y+31}" text-anchor="middle" font-size="11">its pixels: 200–599</text>')
# memory scale
y = 420
a(f'  <text x="{X(0):g}" y="{y}" font-size="11" fill="#555">The display has memory cycles 1 and 3 of every slot: 2 words a slot, 640 a line, about 12 words for every 16 pixels.</text>')
a(f'  <text x="{X(0):g}" y="{y+16}" font-size="11" fill="#555">Sprites share them with the layers, earliest deadline first, and also get cycles nobody else wants.</text>')
a(f'  <text x="{X(864):g}" y="{y+36}" text-anchor="end" font-size="11" fill="#555">The beam is to scale; when each fetch lands is not</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
