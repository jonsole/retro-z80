import sys
out = sys.argv[1]
W, H = 760, 400
L = []; a = L.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
cards = [
    ('#d5a6bd', 'Sprites', 'DEPTH 0', 's'),
    ('#f4b183', 'PRI tiles', 'any layer', 't'),
    ('#cfe2f3', 'FRONT', 'layer', 'l'),
    ('#d5a6bd', 'Sprites', 'DEPTH 1', 's'),
    ('#cfe2f3', 'MIDDLE', 'layer', 'l'),
    ('#d5a6bd', 'Sprites', 'DEPTH 2', 's'),
    ('#cfe2f3', 'BACK', 'layer', 'l'),
    ('#d5a6bd', 'Sprites', 'DEPTH 3', 's'),
    ('#d9d9d9', 'BGCOLOR', '', 'b'),
]
y = 70
# draw back to front so that front cards overlap
for k in reversed(range(len(cards))):
    fill, t1, t2, kind = cards[k]
    x = 80 + k * 74
    pts = f'{x},{y+30} {x+44},{y} {x+44},{y+170} {x},{y+200}'
    if kind == 's':
        a(f'  <polygon points="{pts}" fill="#ffffff" fill-opacity="0.85" stroke="#333" stroke-dasharray="4 3"/>')
        # two small sprites on a transparent plane
        a(f'  <polygon points="{x+8},{y+65} {x+30},{y+52} {x+30},{y+82} {x+8},{y+95}" fill="{fill}" stroke="#333"/>')
        a(f'  <polygon points="{x+14},{y+125} {x+36},{y+112} {x+36},{y+137} {x+14},{y+150}" fill="{fill}" stroke="#333"/>')
    elif kind == 't':
        a(f'  <polygon points="{pts}" fill="#ffffff" fill-opacity="0.85" stroke="#333" stroke-dasharray="4 3"/>')
        a(f'  <polygon points="{x+6},{y+100} {x+38},{y+81} {x+38},{y+111} {x+6},{y+130}" fill="{fill}" stroke="#333"/>')
    else:
        a(f'  <polygon points="{pts}" fill="{fill}" fill-opacity="0.9" stroke="#333"/>')
for k, (fill, t1, t2, kind) in enumerate(cards):
    x = 80 + k * 74 + 22
    a(f'  <text x="{x}" y="{y+224}" text-anchor="middle">{t1}</text>')
    if t2:
        a(f'  <text x="{x}" y="{y+240}" text-anchor="middle" font-size="11" fill="#555">{t2}</text>')
    a(f'  <text x="{x}" y="{y-14}" text-anchor="middle" font-size="11" fill="#555">{k+1}</text>')
a(f'  <text x="20" y="28" font-size="15" font-weight="bold">From the front</text>')
a(f'  <text x="740" y="28" font-size="15" font-weight="bold" text-anchor="end">to the back</text>')
# the line of sight
a(f'  <line x1="30" y1="{y+100}" x2="718" y2="{y+100}" stroke="#777" stroke-dasharray="4 3"/>')
a(f'  <polygon points="30,{y+100} 40,{y+95} 40,{y+105}" fill="#777"/>')
a(f'  <text x="26" y="{y+90}" font-size="11" fill="#555">eye</text>')
# PRIO example
yy = y + 278
a(f'  <text x="20" y="{yy}">With PRIO = L1 in front, then L0, then L2: FRONT is L1, MIDDLE is L0, BACK is L2.</text>')
a(f'  <text x="20" y="{yy+20}">Each pixel shows the first opaque source, looking from the front. Among sprites at the same DEPTH,</text>')
a(f'  <text x="20" y="{yy+40}">the lower-numbered sprite is in front.</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
