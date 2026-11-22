#!/usr/bin/env python3
"""Authors the brand masters (assets/brand/*.svg) and rasterises the launcher icons.

Run from app/:

    python3 tool/make_brand_assets.py            # write masters + icons
    python3 tool/make_brand_assets.py --check    # write nothing, report what would change

The mark is a terminal prompt: a chevron over an underscore, both drawn as round-capped
strokes. Strokes become filled outlines (one rectangle per segment plus a circle at every
vertex and end), so each glyph is plain fill geometry that both `tool/make_brand_mark.py`
(Dart paths) and the rasteriser below can consume.

After running this, run `python3 tool/make_brand_mark.py` to regenerate
lib/ui/shell/brand_glyph.g.dart from the new masters.
"""
import math
import os
import sys

from PIL import Image, ImageDraw

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(APP, 'assets', 'brand')
RES = os.path.join(APP, 'android', 'app', 'src', 'main', 'res')

# ── the mark, in the launcher's 108 grid ──────────────────────────────────────
WIDTH = 10.0                 # stroke width
CHEVRON = [(34.25, 36.5), (53.75, 54.0), (34.25, 71.5)]
UNDERSCORE = [(60.75, 71.5), (73.75, 71.5)]

# Every shape stays inside the 66-unit safe circle (radius 33 about 54,54).
SAFE_RADIUS = 33.0

K = 0.5522847498307933       # cubic approximation of a quarter circle

# ── colours (the app's palette) ───────────────────────────────────────────────
GLYPH_ON_LIGHT = ('#4261CD', '#5E93E1')     # indigo → blue, on near-white tiles
GLYPH_ON_TILE = ('#FFFFFF', '#DCE9FF')      # white → pale blue, on the periwinkle tile
GLYPH_ON_DARK = ('#8FAFFA', '#DDEEFD')      # pale, for dark tiles
TILE_LIGHT = ('#9AB0E8', '#405AAD')         # periwinkle tile
TILE_FROST = ('#FCFDFF', '#DDE5F8')
TILE_INK = ('#292B30', '#0D0E11')
TILE_NIGHT = ('#2C3D6C', '#0C122D')

MARK = 'terminal prompt'     # used in the SVG comments


# ── geometry → path data ─────────────────────────────────────────────────────
def stroke_shapes(points, width):
    """(polygons, circles) covering a round-capped polyline."""
    r = width / 2
    polys, circles = [], [(points[0], r), (points[-1], r)]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        dx, dy = x1 - x0, y1 - y0
        n = math.hypot(dx, dy)
        nx, ny = -dy / n * r, dx / n * r
        polys.append([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
                      (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)])
        circles.append(((x0, y0), r))          # round join
    return polys, circles


def c_line(p0, p1):
    """A straight segment as one cubic (the masters accept only M and C)."""
    (x0, y0), (x1, y1) = p0, p1
    return ((x0 + (x1 - x0) / 3, y0 + (y1 - y0) / 3),
            (x0 + 2 * (x1 - x0) / 3, y0 + 2 * (y1 - y0) / 3), p1)


def c_arcs(cx, cy, r):
    """A full circle as four cubics."""
    d = K * r
    return [((cx + d, cy - r), (cx + r, cy - d), (cx + r, cy)),
            ((cx + r, cy + d), (cx + d, cy + r), (cx, cy + r)),
            ((cx - d, cy + r), (cx - r, cy + d), (cx - r, cy)),
            ((cx - r, cy - d), (cx - d, cy - r), (cx, cy - r))]


def fmt(v):
    s = f'{v:.3f}'.rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def svg_path(points, width):
    """Round-capped polyline as an `M … C … Z` fill path."""
    polys, circles = stroke_shapes(points, width)
    out = []
    for poly in polys:
        out.append(f'M{fmt(poly[0][0])} {fmt(poly[0][1])}')
        for a, b in zip(poly, poly[1:] + poly[:1]):
            c1, c2, p = c_line(a, b)
            out.append(f'C{fmt(c1[0])} {fmt(c1[1])} {fmt(c2[0])} {fmt(c2[1])} {fmt(p[0])} {fmt(p[1])}')
        out.append('Z')
    for (cx, cy), r in circles:
        out.append(f'M{fmt(cx + r)} {fmt(cy)}')
        for c1, c2, p in c_arcs(cx, cy, r):
            out.append(f'C{fmt(c1[0])} {fmt(c1[1])} {fmt(c2[0])} {fmt(c2[1])} {fmt(p[0])} {fmt(p[1])}')
        out.append('Z')
    return ''.join(out)


def vd_path(points, width):
    """The same polyline for a VectorDrawable: rectangles with L, ends as arcs."""
    r = width / 2
    d = []
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        dx, dy = x1 - x0, y1 - y0
        n = math.hypot(dx, dy)
        nx, ny = -dy / n * r, dx / n * r
        pts = [(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]
        d.append(f'M{fmt(pts[0][0])},{fmt(pts[0][1])}')
        for x, y in pts[1:]:
            d.append(f'L{fmt(x)},{fmt(y)}')
        d.append('Z')
    for pt in (points[0], points[-1]):
        cx, cy = pt
        d.append(f'M{fmt(cx - r)},{fmt(cy)}'
                 f'a{fmt(r)},{fmt(r)} 0 1,0 {fmt(2 * r)},0'
                 f'a{fmt(r)},{fmt(r)} 0 1,0 {fmt(-2 * r)},0Z')
    return ''.join(d)


def box_of(points, width):
    r = width / 2
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs) - r, min(ys) - r, max(xs) + r, max(ys) + r


def check_safe():
    """Ink is the segconvex hulls plus a disc of radius width/2 at every point: the
    farthest ink is a cap or join disc's rim, so measure |p - centre| + width/2."""
    r = WIDTH / 2
    for name, pts in (('chevron', CHEVRON), ('underscore', UNDERSCORE)):
        for p in pts:
            d = math.hypot(p[0] - 54, p[1] - 54) + r
            if d > SAFE_RADIUS + 1e-9:
                sys.exit(f'{name} point {p} reaches {d:.2f} from centre; '
                         f'the adaptive-icon safe circle is {SAFE_RADIUS}')


# ── SVG masters ──────────────────────────────────────────────────────────────
HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}">\n'
        '<!-- dsh-fusion · {what}: {mark}. app/tool/make_brand_assets.py authors this file; '
        'app/tool/make_brand_mark.py turns it into app/lib/ui/shell/brand_glyph.g.dart. -->\n')

TILE_PATH = ('M34.58 18C31.39 18.13 29.27 18.57 27.14 19.54C23.87 21.03 21.03 23.87 19.54 27.14'
             'C18.57 29.27 18.13 31.39 18 34.58C18 34.58 18 73.42 18 73.42C18.13 76.61 18.57 78.73 '
             '19.54 80.86C21.03 84.13 23.87 86.97 27.14 88.46C29.27 89.43 31.39 89.87 34.58 90'
             'C34.58 90 73.42 90 73.42 90C76.61 89.87 78.73 89.43 80.86 88.46C84.13 86.97 86.97 84.13 '
             '88.46 80.86C89.43 78.73 89.87 76.61 90 73.42C90 73.42 90 34.58 90 34.58C89.87 31.39 '
             '89.43 29.27 88.46 27.14C86.97 23.87 84.13 21.03 80.86 19.54C78.73 18.57 76.61 18.13 '
             '73.42 18C73.42 18 34.58 18 34.58 18Z')


def glyph_layers(points_chevron, points_underscore):
    return (f'<path id="body" fill="url(#tail)" d="{svg_path(points_chevron, WIDTH)}"/>'
            f'<path id="fin-layer" fill="url(#fin)" d="M54 54Z"/>'
            f'<path id="belly-layer" fill="url(#belly)" d="M54 54Z"/>'
            f'<path id="bubble-layer" fill="url(#bubble)" d="{svg_path(points_underscore, WIDTH)}"/>')


def gradients(a, b, belly_stop):
    return (
        '<defs>'
        f'<linearGradient id="tail" gradientUnits="userSpaceOnUse" x1="36" y1="70" x2="62" y2="38">'
        f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
        f'<linearGradient id="fin" gradientUnits="userSpaceOnUse" x1="36" y1="70" x2="62" y2="38">'
        f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
        f'<radialGradient id="belly" gradientUnits="userSpaceOnUse" cx="54" cy="54" r="30">'
        f'<stop offset="0" stop-color="{belly_stop}"/><stop offset="1" stop-color="{belly_stop}"/>'
        '</radialGradient>'
        f'<linearGradient id="bubble" gradientUnits="userSpaceOnUse" x1="62.5" y1="71.5" x2="76" y2="71.5">'
        f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
        '</defs>')


def masters():
    x0, y0, x1, y1 = box_of(CHEVRON + UNDERSCORE, WIDTH)
    vb = f'{fmt(x0)} {fmt(y0)} {fmt(x1 - x0)} {fmt(y1 - y0)}'

    light = (HEAD.format(vb=vb, what='colour glyph, light backgrounds', mark=MARK)
             + gradients(GLYPH_ON_LIGHT[0], GLYPH_ON_LIGHT[1], '#8CB4F0')
             + glyph_layers(CHEVRON, UNDERSCORE) + '</svg>\n')

    dark = (HEAD.format(vb=vb, what='colour glyph, dark backgrounds', mark=MARK)
            + gradients(GLYPH_ON_DARK[0], GLYPH_ON_DARK[1], '#F2F7FF')
            + glyph_layers(CHEVRON, UNDERSCORE) + '</svg>\n')

    mono = (HEAD.format(vb=vb, what='monochrome glyph', mark=MARK)
            + f'<path id="body" fill="currentColor" d="{svg_path(CHEVRON, WIDTH)}"/>'
            + f'<path id="bubble-layer" fill="currentColor" d="{svg_path(UNDERSCORE, WIDTH)}"/></svg>\n')

    tile = (HEAD.format(vb='18 18 72 72', what='app tile', mark=MARK)
            + gradients(GLYPH_ON_TILE[0], GLYPH_ON_TILE[1], '#EAF2FF')
            .replace('<defs>', f'<defs><linearGradient id="tile-bg" gradientUnits="userSpaceOnUse" '
                               f'x1="7.57" y1="-5.87" x2="100.43" y2="113.87">'
                               f'<stop offset="0" stop-color="{TILE_LIGHT[0]}"/>'
                               f'<stop offset="1" stop-color="{TILE_LIGHT[1]}"/></linearGradient>')
            + f'<path id="tile" fill="url(#tile-bg)" d="{TILE_PATH}"/>'
            + glyph_layers(CHEVRON, UNDERSCORE) + '</svg>\n')

    return {'glyph-light.svg': light, 'glyph-dark.svg': dark,
            'glyph-mono.svg': mono, 'tile.svg': tile}


# ── raster launcher icons ────────────────────────────────────────────────────
DENSITIES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}


def gradient_image(size, top, bottom, vertical=True):
    im = Image.new('RGB', (size, size))
    px = im.load()
    for y in range(size):
        for x in range(size):
            t = (y if vertical else x) / (size - 1)
            px[x, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return im


def hex_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def draw_mark(size, scale=1.0, offset=0.0):
    """Glyph mask on a transparent `size` canvas, unit = 108 grid → pixels."""
    unit = size / 108 * scale
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = WIDTH / 2 * unit
    off = offset * unit

    def px(p):
        return (p[0] * unit + off, p[1] * unit + off)

    for pts in (CHEVRON, UNDERSCORE):
        for a, b in zip(pts, pts[1:]):
            (x0, y0), (x1, y1) = px(a), px(b)
            dx, dy = x1 - x0, y1 - y0
            n = math.hypot(dx, dy)
            nx, ny = -dy / n * r, dx / n * r
            d.polygon([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
                       (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], fill=255)
        for p in pts:
            cx, cy = px(p)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    return mask


def tile_mask(size, round_icon):
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    if round_icon:
        d.ellipse([0, 0, size - 1, size - 1], fill=255)
    else:
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.2237), fill=255)
    return m


def compose(size, tile_colors, glyph_colors, round_icon=False, with_tile=True):
    gly = draw_mark(size)
    grad = gradient_image(size, hex_rgb(glyph_colors[0]), hex_rgb(glyph_colors[1]))
    glyph = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    glyph.paste(grad.convert('RGBA'), (0, 0), gly)
    if not with_tile:
        return glyph
    bg = gradient_image(size, hex_rgb(tile_colors[0]), hex_rgb(tile_colors[1])).convert('RGBA')
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), tile_mask(size, round_icon))
    out.paste(glyph, (0, 0), gly)
    return out


def foreground(size):
    """Adaptive foreground: glyph only, scaled about the centre to the safe circle."""
    # the glyph already lives inside radius 33; the layer is 108 units wide
    return compose(size, TILE_LIGHT, GLYPH_ON_TILE, with_tile=False)


VARIANTS = [
    ('', TILE_LIGHT, GLYPH_ON_TILE),
    ('_frost', TILE_FROST, GLYPH_ON_LIGHT),
    ('_ink', TILE_INK, GLYPH_ON_DARK),
    ('_night', TILE_NIGHT, GLYPH_ON_DARK),
]


def icon_files():
    """{path: PIL image} for every launcher asset."""
    out = {}
    for suffix, tile_colors, glyph_colors in VARIANTS:
        for dens, px in DENSITIES.items():
            out[f'mipmap-{dens}/ic_launcher{suffix}.png'] = \
                compose(px, tile_colors, glyph_colors)
            out[f'mipmap-{dens}/ic_launcher{suffix}_round.png'] = \
                compose(px, tile_colors, glyph_colors, round_icon=True)
            if suffix:
                out[f'mipmap-{dens}/ic_launcher{suffix}_foreground.png'] = foreground(px * 9 // 4)
        if not suffix:
            out[f'mipmap-{dens}/ic_launcher_foreground.png'] = foreground(px * 9 // 4)
    return out


MONO_XML = '''<?xml version="1.0" encoding="utf-8"?>
<!-- Themed-icon (Android 13+) layer: the dsh-fusion mark (terminal prompt) on the 108 grid,
     the same placement as mipmap/ic_launcher_foreground. Authored by tool/make_brand_assets.py. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="{chevron}" />
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="{underscore}" />
</vector>
'''


def main():
    check = '--check' in sys.argv
    check_safe()
    changed = []

    for name, text in masters().items():
        p = os.path.join(ASSETS, name)
        old = open(p, encoding='utf-8').read() if os.path.exists(p) else None
        if old != text:
            changed.append(os.path.relpath(p, APP))
            if not check:
                open(p, 'w', encoding='utf-8').write(text)

    for rel, im in icon_files().items():
        p = os.path.join(RES, rel)
        if not (os.path.exists(p) and Image.open(p).tobytes() == im.tobytes()):
            changed.append(os.path.relpath(p, APP))
            if not check:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                im.save(p, optimize=True)

    xml = MONO_XML.format(chevron=vd_path(CHEVRON, WIDTH), underscore=vd_path(UNDERSCORE, WIDTH))
    p = os.path.join(RES, 'drawable', 'ic_launcher_monochrome.xml')
    if not (os.path.exists(p) and open(p, encoding='utf-8').read() == xml):
        changed.append(os.path.relpath(p, APP))
        if not check:
            open(p, 'w', encoding='utf-8').write(xml)

    verb = 'would change' if check else 'wrote'
    if changed:
        print(f'{verb} {len(changed)} file(s):')
        for c in changed[:8]:
            print('  ', c)
        if len(changed) > 8:
            print(f'   … and {len(changed) - 8} more')
    else:
        print('everything up to date')


if __name__ == '__main__':
    main()
