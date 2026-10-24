import sys
out = sys.argv[1]
W, H = 760, 420
L = []; a = L.append
X0, U = 300, 24
X = lambda w: X0 + w * U
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
a(f'  <text x="20" y="24" font-size="15" font-weight="bold">Words for the same 16 screen pixels</text>')
# spare region
a(f'  <rect x="{X(12)}" y="44" width="{6*U}" height="300" fill="#f3f3f3" stroke="#777" stroke-dasharray="4 3"/>')
a(f'  <text x="{X(15)}" y="60" text-anchor="middle" font-size="11" fill="#555">about 6 more:</text>')
a(f'  <text x="{X(15)}" y="74" text-anchor="middle" font-size="11" fill="#555">the CPU\'s spare</text>')
a(f'  <text x="{X(15)}" y="88" text-anchor="middle" font-size="11" fill="#555">cycles, not certain</text>')
# axis
for w in range(0, 19, 2):
    a(f'  <line x1="{X(w)}" y1="344" x2="{X(w)}" y2="350" stroke="#777"/>')
    a(f'  <text x="{X(w)}" y="363" text-anchor="middle" font-size="11" fill="#555">{w}</text>')
a(f'  <line x1="{X(12)}" y1="40" x2="{X(12)}" y2="350" stroke="#333" stroke-width="2"/>')
a(f'  <text x="{X(12)}" y="36" text-anchor="middle" font-size="11">12: cycles 1 and 3, certain</text>')
rows = [
    ('No layers', 'three 4 bpp sprites', [], [4, 4, 4]),
    ('No layers', 'one 8 bpp sprite', [], [8]),
    ('Spectrum screen (about 1)', 'two 4 bpp sprites', [1], [4, 4]),
    ('One 8 bpp layer at 2× (4)', 'two 4 bpp sprites', [4], [4, 4]),
    ('4 bpp tile layer at 1× (about 6)', 'one 4 bpp sprite', [6], [4]),
    ('One 8 bpp layer at 1× (8)', 'one 4 bpp sprite', [8], [4]),
    ('Three 4 bpp layers at 1× (12)', 'no room for sprites', [4, 4, 4], []),
]
for i, (t1, t2, lay, spr) in enumerate(rows):
    y = 104 + i * 34
    a(f'  <text x="{X0-10}" y="{y+11}" text-anchor="end">{t1}</text>')
    a(f'  <text x="{X0-10}" y="{y+25}" text-anchor="end" font-size="11" fill="#555">{t2}</text>')
    x = 0
    for w in lay:
        a(f'  <rect x="{X(x)}" y="{y}" width="{w*U}" height="26" fill="#cfe2f3" stroke="#333"/>')
        x += w
    for w in spr:
        a(f'  <rect x="{X(x)}" y="{y}" width="{w*U}" height="26" fill="#d5a6bd" stroke="#333"/>')
        a(f'  <text x="{X(x)+w*U/2}" y="{y+17}" text-anchor="middle" font-size="11">{w}</text>')
        x += w
a(f'  <text x="{X(9)}" y="384" text-anchor="middle" font-size="11" fill="#555">words per 16 screen pixels (a sprite at normal size needs BPP words)</text>')
yl = 398
a(f'  <rect x="20" y="{yl}" width="14" height="14" fill="#cfe2f3" stroke="#333"/>')
a(f'  <text x="40" y="{yl+11}" font-size="11">layers</text>')
a(f'  <rect x="100" y="{yl}" width="14" height="14" fill="#d5a6bd" stroke="#333"/>')
a(f'  <text x="120" y="{yl+11}" font-size="11">sprites over the same pixels</text>')
a(f'  <text x="740" y="{yl+11}" text-anchor="end" font-size="11" fill="#555">To scale</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
