#!/usr/bin/env python3
"""Generates the DSH Fusion launcher icon (a geometric F mark) for every density.

Keeps the existing blue diagonal gradient background drawable and replaces only what carries the
old whale: the adaptive-icon foreground, the legacy square/round raster icons, and the themed
(monochrome) silhouette. Run from the repo root:

    python3 tooling/fusion-icon/make_icons.py
"""
from PIL import Image, ImageDraw
import os, sys

RES = os.path.join(os.path.dirname(__file__), '..', '..',
                   'app', 'android', 'app', 'src', 'main', 'res')

# Same gradient the background drawable paints (#9AB0E8 -> #405AAD, top-left -> bottom-right).
TOP = (154, 176, 232)
BOTTOM = (64, 90, 173)

# Adaptive icon: 108dp canvas, glyph must stay inside the centre 72dp (safe zone).
ADAPTIVE = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
LEGACY = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}


def gradient(size):
    img = Image.new('RGBA', (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(size - 1, 1)
        d.line([(0, y), (size, y)],
               fill=(round(TOP[0] + (BOTTOM[0] - TOP[0]) * t),
                     round(TOP[1] + (BOTTOM[1] - TOP[1]) * t),
                     round(TOP[2] + (BOTTOM[2] - TOP[2]) * t), 255))
    return img


def draw_mark(size, scale=1.0, offset=(0, 0)):
    """The mark itself: a stem and two arms (an F), strokes rounded, drawn in white."""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    unit = size * scale
    # Geometry inside a 100-unit box, centred, then scaled to `unit`.
    def box(x, y, w, h):
        return [
            offset[0] + (size - unit) / 2 + x / 100 * unit,
            offset[1] + (size - unit) / 2 + y / 100 * unit,
            offset[0] + (size - unit) / 2 + (x + w) / 100 * unit,
            offset[1] + (size - unit) / 2 + (y + h) / 100 * unit,
        ]
    r = 9 / 100 * unit               # stroke cap radius, in pixels
    white = (255, 255, 255, 255)
    # stem
    d.rounded_rectangle(box(28, 20, 16, 60), radius=r, fill=white)
    # top arm
    d.rounded_rectangle(box(28, 20, 44, 16), radius=r, fill=white)
    # middle arm (shorter, reads as the F's crossbar)
    d.rounded_rectangle(box(28, 45, 32, 16), radius=r, fill=white)
    return layer


def write(path, img):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, 'PNG', optimize=True)


def main():
    made = []
    for density, px in ADAPTIVE.items():
        # Foreground: transparent, glyph in the safe zone (~62% of the canvas).
        fg = draw_mark(px, scale=0.62)
        write(os.path.join(RES, f'mipmap-{density}', 'ic_launcher_foreground.png'), fg)
        made.append(f'mipmap-{density}/ic_launcher_foreground.png')
    for density, px in LEGACY.items():
        base = gradient(px)
        base.alpha_composite(draw_mark(px, scale=0.70))
        write(os.path.join(RES, f'mipmap-{density}', 'ic_launcher.png'), base)
        # Round variant: same art inside a circle.
        mask = Image.new('L', (px, px), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, px - 1, px - 1], fill=255)
        round_img = Image.new('RGBA', (px, px), (0, 0, 0, 0))
        round_img.paste(base, (0, 0), mask)
        write(os.path.join(RES, f'mipmap-{density}', 'ic_launcher_round.png'), round_img)
        made.append(f'mipmap-{density}/ic_launcher{{,_round}}.png')
    print('\n'.join(made))


if __name__ == '__main__':
    sys.exit(main())
