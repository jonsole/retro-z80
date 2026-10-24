import sys
out = sys.argv[1]
W, H = 760, 380
L = []; a = L.append
C = 16; GX, GY = 20, 60; NC, NR = 26, 16
cell = lambda c, r: (GX + c * C, GY + r * C)
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
a(f'  <text x="20" y="28" font-size="15" font-weight="bold">Part of the picture</text>')
a(f'  <text x="20" y="46" font-size="11" fill="#555">Each square is a picture pixel. Collisions are found as each line is drawn</text>')
def rows(d):
    s = set()
    for r, cs in d.items():
        for c in cs: s.add((c, r))
    return s
s0 = rows({4: [6, 7], 5: range(5, 9), 6: range(4, 10), 7: range(3, 11), 8: range(4, 10), 9: [5, 8]})
s3 = rows({3: [10, 11], 4: range(9, 13), 5: range(8, 14), 6: range(8, 14), 7: range(9, 13), 8: [10, 11]})
s5 = rows({10: range(2, 5), 11: range(1, 6), 12: range(2, 5), 13: [3]})
l1 = {(c, r) for c in range(7, 10) for r in range(9, 16)} | {(c, r) for c in range(NC) for r in range(14, 16)}
# grid
for c in range(NC):
    for r in range(NR):
        x, y = cell(c, r)
        p = (c, r)
        n = (p in s0) + (p in s3) + (p in s5)
        if n >= 2 or (p in l1 and n >= 1):
            f = '#f4b183'
        elif n == 1:
            f = '#d5a6bd'
        elif p in l1:
            f = '#cfe2f3'
        else:
            f = '#ffffff'
        a(f'  <rect x="{x}" y="{y}" width="{C}" height="{C}" fill="{f}" stroke="#d9d9d9"/>')
a(f'  <rect x="{GX}" y="{GY}" width="{NC*C}" height="{NR*C}" fill="none" stroke="#333"/>')
# sprite boxes
for (c0, r0, c1, r1, name, tx, ty) in [(3, 4, 10, 9, 'sprite 0', 3, 3.6), (8, 3, 13, 8, 'sprite 3', 14.2, 3.8), (1, 9, 5, 13, 'sprite 5', 1, 8.6)]:
    x, y = cell(c0, r0)
    a(f'  <rect x="{x}" y="{y}" width="{(c1-c0+1)*C}" height="{(r1-r0+1)*C}" fill="none" stroke="#333" stroke-dasharray="4 3"/>')
    a(f'  <text x="{GX+tx*C}" y="{GY+ty*C}" font-size="11">{name}</text>')
a(f'  <text x="{GX+10*C+6}" y="{GY+12.4*C}" font-size="11">layer 1</text>')
# right panel
px = 470
a(f'  <text x="{px}" y="80" font-weight="bold">SPRCOLL afterwards</text>')
regs = [('SPRCOLL0', 'SPR', 0x09), ('SPRCOLL1', 'L0', 0x00), ('SPRCOLL2', 'L1', 0x01), ('SPRCOLL3', 'L2', 0x00)]
bx = px + 100; BW = 18
for i in range(8):
    a(f'  <text x="{bx + i*BW + BW/2}" y="104" text-anchor="middle" font-size="11" fill="#555">{7-i}</text>')
for j, (n, f, v) in enumerate(regs):
    y = 112 + j * 34
    a(f'  <text x="{px}" y="{y+14}" font-size="11">{n} ({f})</text>')
    for i in range(8):
        b = (v >> (7 - i)) & 1
        a(f'  <rect x="{bx + i*BW}" y="{y}" width="{BW}" height="20" fill="{"#f4b183" if b else "#ffffff"}" stroke="#333"/>')
        a(f'  <text x="{bx + i*BW + BW/2}" y="{y+14}" text-anchor="middle" font-size="11">{b}</text>')
    a(f'  <text x="{bx + 8*BW + 8}" y="{y+14}" font-size="11">0x{v:02X}</text>')
notes = ['Sprites 0 and 3 overlap: bits 0 and 3 of SPRCOLL0.',
         'Sprite 0 is on layer 1: bit 0 of SPRCOLL2.',
         'Sprite 5\'s window overlaps sprite 0\'s, but only',
         'transparent pixels meet: no bit for sprite 5.']
for k, t in enumerate(notes):
    a(f'  <text x="{px}" y="{270 + k*18}" font-size="11">{t}</text>')
# legend
yl = H - 26
items = [('#d5a6bd', 'opaque sprite pixel'), ('#cfe2f3', 'opaque layer 1 pixel'), ('#f4b183', 'collision')]
x = 20
for f, t in items:
    a(f'  <rect x="{x}" y="{yl}" width="14" height="14" fill="{f}" stroke="#333"/>')
    a(f'  <text x="{x+20}" y="{yl+11}" font-size="11">{t}</text>')
    x += 160
a(f'  <rect x="{x}" y="{yl}" width="14" height="14" fill="none" stroke="#333" stroke-dasharray="4 3"/>')
a(f'  <text x="{x+20}" y="{yl+11}" font-size="11">sprite window</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
