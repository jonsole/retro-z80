import sys
out = sys.argv[1]
W, H = 760, 465
L = []; a = L.append
X = lambda p: 130 + 0.69 * p
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
# pixel axis
a(f'  <text x="{X(432):g}" y="20" text-anchor="middle">beam pixels</text>')
for p, t in [(0, '0'), (144, '144'), (864, '864')]:
    a(f'  <line x1="{X(p):g}" y1="34" x2="{X(p):g}" y2="42" stroke="#777"/>')
    a(f'  <text x="{X(p):g}" y="31" text-anchor="middle" font-size="11" fill="#555">{t}</text>')
rows = [('line E − 1', ''), ('line E', 'the old use\'s last line'), ('line E + 1', 'the gap line'), ('line E + 2', 'the new use\'s first line'), ('line E + 3', '')]
ys = [50, 110, 190, 300, 360]
for (name, sub), y in zip(rows, ys):
    a(f'  <rect x="{X(0):g}" y="{y}" width="{X(144)-X(0):g}" height="28" fill="#d9d9d9" stroke="#333"/>')
    a(f'  <rect x="{X(144):g}" y="{y}" width="{X(864)-X(144):g}" height="28" fill="#cfe2f3" stroke="#333"/>')
    a(f'  <text x="{X(0)-8:g}" y="{y+13}" text-anchor="end">{name}</text>')
    if sub:
        a(f'  <text x="{X(0)-8:g}" y="{y+27}" text-anchor="end" font-size="11" fill="#555">{sub}</text>')
# old use 344-408 on lines E-1 and E
for y in ys[:2]:
    a(f'  <rect x="{X(344):g}" y="{y+4}" width="{X(408)-X(344):g}" height="20" fill="#d5a6bd" stroke="#333"/>')
    a(f'  <text x="{(X(344)+X(408))/2:g}" y="{y+18}" text-anchor="middle" font-size="11">old use</text>')
# new use 520-584 on lines E+2, E+3
for y in ys[3:]:
    a(f'  <rect x="{X(520):g}" y="{y+4}" width="{X(584)-X(520):g}" height="20" fill="#d5a6bd" stroke="#333"/>')
    a(f'  <text x="{(X(520)+X(584))/2:g}" y="{y+18}" text-anchor="middle" font-size="11">new use</text>')
y = ys[2]
# copper: WAIT at pixel 0, 12 MOVEs by about pixel 32 (PRI 1, one a slot)
a(f'  <rect x="{X(0):g}" y="{y+4}" width="{X(30)-X(0):g}" height="20" fill="#ffe599" stroke="#333"/>')
a(f'  <line x1="{X(30):g}" y1="{y-4}" x2="{X(30):g}" y2="{y+32}" stroke="#333" stroke-width="2"/>')
a(f'  <line x1="{X(16):g}" y1="{y-30}" x2="{X(16):g}" y2="{y+4}" stroke="#777"/>')
a(f'  <text x="{X(16)+6:g}" y="{y-36}" font-size="11">copper: CWAIT (E + 1, 0), then 12 MOVEs (H, V, PT, CTL): CTL lands about 30 pixels later at PRI 1</text>')
# sequencer window 16-836 and the freeze 840-847
a(f'  <line x1="{X(16):g}" y1="{y+40}" x2="{X(836):g}" y2="{y+40}" stroke="#777"/>')
for p in (16, 836):
    a(f'  <line x1="{X(p):g}" y1="{y+35}" x2="{X(p):g}" y2="{y+45}" stroke="#777"/>')
a(f'  <rect x="{X(240):g}" y="{y+33}" width="{X(620)-X(240):g}" height="14" fill="#ffffff"/>')
a(f'  <text x="{X(430):g}" y="{y+44}" text-anchor="middle" font-size="11">or the sequencer: its writes land in pixels 16–836</text>')
a(f'  <rect x="{X(840):g}" y="{y}" width="{X(848)-X(840):g}" height="28" fill="#f4b183" stroke="#333"/>')
a(f'  <line x1="{X(844):g}" y1="{y+28}" x2="{X(844):g}" y2="{y+62}" stroke="#777"/>')
a(f'  <text x="{X(844):g}" y="{y+75}" text-anchor="end" font-size="11">840–847: line E + 2\'s sizes are worked out from H, V and STEP</text>')
# notes
a(f'  <text x="20" y="{H-38}">Old use: VSTOP = E + 1. A CTL write in line E + 1 starts the sprite again; its first line is the next</text>')
a(f'  <text x="20" y="{H-18}">line inside its window. So the new use can start on line E + 2 or later: new VSTART ≥ old VSTOP + 1.</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
