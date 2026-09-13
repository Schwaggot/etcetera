#!/usr/bin/env python3
"""Poppins Bold, converted to outlines. Square canvas, no mask.

Poppins is SIL OFL 1.1. Outlines in a logo are permitted; the font file itself
is not redistributed here.
"""

import os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen

S = 1024
GRID_SPAN = 700
CELL = GRID_SPAN / 4
G0 = (S - GRID_SPAN) / 2
XHEIGHT = 275              # matches the drawn set, so the two are swappable
DOT_BOOST = 1.45           # the period alone is too light for its cell
FONT = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"
OUT = os.path.dirname(os.path.abspath(__file__))

_cache = {}
def outline(char):
    if char not in _cache:
        f = TTFont(FONT)
        gs = f.getGlyphSet()
        name = f.getBestCmap()[ord(char)]
        pen = SVGPathPen(gs); gs[name].draw(pen)
        bp = BoundsPen(gs); gs[name].draw(bp)
        _cache[char] = (pen.getCommands(), bp.bounds)
    return _cache[char]

_, EB = outline("e")
SCALE = XHEIGHT / (EB[3] - EB[1])


def fmt(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def placed(char, cx, baseline, boost=1.0, clip=None):
    """Centre on cx, sit on baseline. Font y is up, SVG y is down."""
    d, bb = outline(char)
    s = SCALE * boost
    w = (bb[2] - bb[0]) * s
    x = cx - w / 2 - bb[0] * s
    cp = f' clip-path="url(#{clip})"' if clip else ""
    return (f'    <g transform="translate({fmt(x)} {fmt(baseline)}) '
            f'scale({s:.5f} {-s:.5f})"{cp}><path d="{d}"/></g>')


def bowl_clip(cid):
    """An ellipse on the bowl, unioned with everything left of centre.

    Trims the crossbar's overhanging corners without touching the rest of the
    glyph, which is not a perfect ellipse. The clip resolves in the referencing
    element's own coordinate system, so these are font units, not canvas units.
    """
    d, bb = outline("e")
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    ecx, ecy = (bb[0] + bb[2]) / 2, (bb[1] + bb[3]) / 2
    return (f'    <clipPath id="{cid}">\n'
            f'      <rect x="{fmt(bb[0] - w)}" y="{fmt(bb[1] - h)}" '
            f'width="{fmt(w * 1.5)}" height="{fmt(h * 3)}"/>\n'
            f'      <ellipse cx="{fmt(ecx)}" cy="{fmt(ecy)}" '
            f'rx="{fmt(w / 2)}" ry="{fmt(h / 2)}"/>\n'
            f'    </clipPath>')


BASE1 = G0 + CELL + XHEIGHT / 2
BASE2 = G0 + 3 * CELL + XHEIGHT / 2
LOCKUP = [("e", G0 + CELL, BASE1, 1.0), ("t", G0 + 3 * CELL, BASE1, 1.0),
          ("c", G0 + CELL, BASE2, 1.0), (".", G0 + 3 * CELL, BASE2, DOT_BOOST)]


def bbox(items):
    xs, ys = [], []
    for char, cx, base, boost in items:
        d, bb = outline(char)
        s = SCALE * boost
        w = (bb[2] - bb[0]) * s
        xs += [cx - w / 2, cx + w / 2]
        ys += [base - (bb[3] - bb[1]) * s, base]
    return min(xs), min(ys), max(xs), max(ys)


X0, Y0, X1, Y1 = bbox(LOCKUP)
DX = S / 2 - (X0 + X1) / 2
DY = (S / 2 - (Y0 + Y1) / 2) * 0.5


def glyphs(fill="#FFFFFF"):
    body = "\n".join(
        placed(c, cx, b, k, clip="bowl" if c == "e" else None)
        for c, cx, b, k in LOCKUP)
    return (f'  <g transform="translate({fmt(DX)} {fmt(DY)})" fill="{fill}">\n'
            f'{bowl_clip("bowl")}\n{body}\n  </g>')


SMALL_X = 430
_ss = SMALL_X / (EB[3] - EB[1])


def small_glyphs(fill="#FFFFFF"):
    global SCALE
    keep, SCALE = SCALE, _ss
    body = (bowl_clip("bowl-s") + "\n"
            + placed("e", 430, 720, clip="bowl-s") + "\n"
            + placed(".", 790, 720, 1.35))
    SCALE = keep
    return f'  <g transform="translate(-16 4)" fill="{fill}">\n{body}\n  </g>'


def raster(opacity=0.09):
    lines = []
    for i in range(1, 4):
        v = G0 + i * CELL
        lines.append(f'    <path d="M {fmt(v)} {fmt(G0)} L {fmt(v)} {fmt(G0 + GRID_SPAN)}"/>')
        lines.append(f'    <path d="M {fmt(G0)} {fmt(v)} L {fmt(G0 + GRID_SPAN)} {fmt(v)}"/>')
    return (f'  <g transform="translate({fmt(DX)} {fmt(DY)})" stroke="#FFFFFF" '
            f'stroke-width="2.3" opacity="{opacity}">\n' + "\n".join(lines) + "\n  </g>")


FIELD = '''  <defs>
    <linearGradient id="field" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0"    stop-color="#6BB2FF"/>
      <stop offset="0.42" stop-color="#2C74E6"/>
      <stop offset="1"    stop-color="#0B3A9E"/>
    </linearGradient>
  </defs>'''

SHADING = '''    <radialGradient id="dome" cx="0.5" cy="0.02" r="0.88">
      <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.26"/>
      <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.06"/>
      <stop offset="1"    stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="floor" cx="0.5" cy="1" r="0.7">
      <stop offset="0" stop-color="#04205C" stop-opacity="0.34"/>
      <stop offset="1" stop-color="#04205C" stop-opacity="0"/>
    </radialGradient>'''

HEAD = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
        f'viewBox="0 0 {S} {S}" role="img" aria-label="etcetera">')


def square(inner, shaded=False, extra=""):
    defs = FIELD.replace("  </defs>", SHADING + "\n  </defs>") if shaded else FIELD
    shade = (f'  <rect width="{S}" height="{S}" fill="url(#floor)"/>\n'
             f'  <rect width="{S}" height="{S}" fill="url(#dome)"/>\n') if shaded else ""
    return f'''{HEAD}
  <title>etcetera</title>
{defs}
  <rect width="{S}" height="{S}" fill="url(#field)"/>
{shade}{extra}{inner}
</svg>'''


def write(name, body):
    open(os.path.join(OUT, name), "w").write(body + "\n")


write("poppins-icon.svg", square(glyphs()))
write("poppins-icon-shaded.svg", square(glyphs(), shaded=True))
write("poppins-icon-raster.svg", square(glyphs(), extra=raster() + "\n"))
write("poppins-icon-small.svg", square(small_glyphs()))

pad = 12
write("poppins-mark.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" width="{fmt(X1-X0+2*pad)}" height="{fmt(Y1-Y0+2*pad)}" viewBox="{fmt(X0+DX-pad)} {fmt(Y0+DY-pad)} {fmt(X1-X0+2*pad)} {fmt(Y1-Y0+2*pad)}" role="img" aria-label="etcetera">
  <title>etcetera</title>
{glyphs("currentColor")}
</svg>''')

write("poppins-mark-small.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" width="780" height="540" viewBox="160 260 780 540" role="img" aria-label="etcetera">
  <title>etcetera</title>
{small_glyphs("currentColor")}
</svg>''')

print(f"scale {SCALE:.4f}  bbox {X1-X0:.0f}x{Y1-Y0:.0f}  shift {DX:.1f},{DY:.1f}")
