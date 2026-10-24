# Writes sprites-4-3-scaling.svg: which source pixel each screen pixel shows
import sys
out = sys.argv[1]
W = 760
L = []
a = L.append
H = 480
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" font-size="13" fill="#1a1a1a">')
a('  <defs>\n    <pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">\n      <line x1="0" y1="0" x2="0" y2="6" stroke="#777" stroke-width="1"/>\n    </pattern>\n  </defs>')
a(f'  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
X0 = 150
def panel(y, title, step, nsrc, nscr):
    a(f'  <text x="20" y="{y}" font-size="15" font-weight="bold">{title}</text>')
    sy, ty = y + 34, y + 134
    sw, tw = 480 / nsrc, 480 / nscr
    shown = {i * step // 2048 for i in range(nscr)}
    a(f'  <text x="{X0-12}" y="{sy+20}" text-anchor="end">source line</text>')
    a(f'  <text x="{X0-12}" y="{ty+20}" text-anchor="end">screen</text>')
    a(f'  <text x="{X0-12}" y="{ty+34}" text-anchor="end" font-size="11" fill="#555">(the window)</text>')
    for k in range(nsrc):
        x = X0 + k * sw
        fill = '#d5a6bd' if k in shown else 'url(#hatch)'
        a(f'  <rect x="{x:g}" y="{sy}" width="{sw:g}" height="30" fill="{fill}" stroke="#333"/>')
        a(f'  <text x="{x+sw/2:g}" y="{sy+20}" text-anchor="middle">{k}</text>')
    for i in range(nscr):
        k = i * step // 2048
        x = X0 + i * tw
        a(f'  <line x1="{X0+k*sw+sw/2:g}" y1="{sy+30}" x2="{x+tw/2:g}" y2="{ty}" stroke="#333"/>')
        a(f'  <rect x="{x:g}" y="{ty}" width="{tw:g}" height="30" fill="#d5a6bd" stroke="#333"/>')
        a(f'  <text x="{x+tw/2:g}" y="{ty+20}" text-anchor="middle">{k}</text>')
        a(f'  <text x="{x+tw/2:g}" y="{ty+46}" text-anchor="middle" font-size="11" fill="#555">i={i}</text>')
panel(26, 'XSTEP 0x0555: 1.5× bigger. 12 screen pixels show 8 source pixels', 0x555, 8, 12)
panel(246, 'XSTEP 0x0C00: 2/3 the size. 8 screen pixels show 12 source pixels', 0xC00, 12, 8)
# notes
a(f'  <rect x="{X0}" y="{H-36}" width="14" height="14" fill="url(#hatch)" stroke="#333"/>')
a(f'  <text x="{X0+20}" y="{H-25}" font-size="11">fetched and skipped: not shown</text>')
a(f'  <text x="{X0+480}" y="{H-25}" font-size="11" fill="#555" text-anchor="end">Screen pixel i shows source pixel ⌊i × XSTEP ÷ 2048⌋</text>')
a('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
