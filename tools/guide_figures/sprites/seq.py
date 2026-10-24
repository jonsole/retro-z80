import sys
out = sys.argv[1]
W, H = 760, 480
L = []; a = L.append
Y = lambda l: 80 + (l - 96) * 6.5
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
cols = {1: 140, 2: 250, 3: 360, 'skip': 480}
CW = 80
for k, x in cols.items():
    t = f'Sprite {k}' if k != 'skip' else 'Skipped'
    a(f'  <text x="{x+CW/2}" y="40" text-anchor="middle" font-weight="bold">{t}</text>')
    a(f'  <line x1="{x+CW/2}" y1="{Y(96)}" x2="{x+CW/2}" y2="{Y(150)}" stroke="#d9d9d9"/>')
# line axis
a(f'  <line x1="100" y1="{Y(96)}" x2="100" y2="{Y(150)}" stroke="#777"/>')
for l in range(96, 151, 2):
    big = l % 8 == 0
    a(f'  <line x1="{94 if big else 97}" y1="{Y(l)}" x2="100" y2="{Y(l)}" stroke="#777"/>')
    if big:
        a(f'  <text x="90" y="{Y(l)+4}" text-anchor="end" font-size="11" fill="#555">{l}</text>')
a(f'  <text x="30" y="{Y(123)}" text-anchor="middle" transform="rotate(-90 30 {Y(123)})">beam line</text>')
uses = [('A', 100, 116, 1, 0), ('B', 104, 120, 2, 0), ('C', 110, 126, 3, 0),
        ('D', 118, 134, 1, 116), ('E', 121, 137, 2, 120), ('G', 130, 146, 3, 126)]
for n, v0, v1, s, g in uses:
    x = cols[s]
    a(f'  <rect x="{x}" y="{Y(v0)}" width="{CW}" height="{Y(v1)-Y(v0)}" fill="#d5a6bd" stroke="#333"/>')
    a(f'  <text x="{x+CW/2}" y="{Y(v0)+16}" text-anchor="middle">{n}</text>')
    a(f'  <text x="{x+CW/2}" y="{Y(v0)+30}" text-anchor="middle" font-size="11">{v0}–{v1-1}</text>')
    if g:
        a(f'  <rect x="{x}" y="{Y(g)}" width="{CW}" height="6.5" fill="#f4b183" stroke="#333"/>')
        a(f'  <text x="{x+CW+4}" y="{Y(g)+6}" font-size="11" fill="#555">{g}</text>')
# F skipped
x = cols['skip']
a(f'  <rect x="{x}" y="{Y(122)}" width="{CW}" height="{Y(138)-Y(122)}" fill="none" stroke="#777" stroke-dasharray="4 3"/>')
a(f'  <text x="{x+CW/2}" y="{Y(122)+16}" text-anchor="middle">F</text>')
a(f'  <text x="{x+CW/2}" y="{Y(122)+30}" text-anchor="middle" font-size="11">122–137</text>')
a(f'  <text x="{x+CW/2}" y="{Y(122)+48}" text-anchor="middle" font-size="11" fill="#555">no sprite free</text>')
a(f'  <text x="{x+CW/2}" y="{Y(122)+62}" text-anchor="middle" font-size="11" fill="#555">by line 121:</text>')
a(f'  <text x="{x+CW/2}" y="{Y(122)+76}" text-anchor="middle" font-size="11" fill="#555">SEQSKIP + 1</text>')
a(f'  <text x="{cols[1]}" y="64" font-size="11" fill="#555">A, B and C are placed in line 0, at the frame start</text>')
# the list
lx = 600
a(f'  <text x="{lx}" y="40" font-weight="bold">The list</text>')
a(f'  <text x="{lx+10}" y="62" font-size="11" fill="#555">entry</text>')
a(f'  <text x="{lx+82}" y="62" font-size="11" fill="#555" text-anchor="end">VSTART</text>')
a(f'  <text x="{lx+136}" y="62" font-size="11" fill="#555" text-anchor="end">VSTOP</text>')
rows = [('A', 100, 116), ('B', 104, 120), ('C', 110, 126), ('D', 118, 134), ('E', 121, 137), ('F', 122, 138), ('G', 130, 146), ('end', '0x7FF', '')]
for i, (n, v0, v1) in enumerate(rows):
    y = 82 + i * 20
    a(f'  <rect x="{lx-4}" y="{y-14}" width="150" height="20" fill="#ffffff" stroke="#777"/>')
    a(f'  <text x="{lx+10}" y="{y}" font-size="11">{n}</text>')
    a(f'  <text x="{lx+82}" y="{y}" font-size="11" text-anchor="end">{v0}</text>')
    a(f'  <text x="{lx+136}" y="{y}" font-size="11" text-anchor="end">{v1}</text>')
a(f'  <text x="{lx}" y="{82+8*20+6}" font-size="11" fill="#555">SEQMASK = 0x0E:</text>')
a(f'  <text x="{lx}" y="{82+8*20+20}" font-size="11" fill="#555">sprites 1–3</text>')
# legend
yl = H - 30
a(f'  <rect x="140" y="{yl}" width="14" height="14" fill="#d5a6bd" stroke="#333"/>')
a(f'  <text x="160" y="{yl+11}" font-size="11">a use, VSTART to VSTOP − 1</text>')
a(f'  <rect x="340" y="{yl}" width="14" height="14" fill="#f4b183" stroke="#333"/>')
a(f'  <text x="360" y="{yl+11}" font-size="11">the gap line where the entry is written</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
