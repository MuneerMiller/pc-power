"""Draws the PC Power icon at every size the apps need, from one drawing (smooth edges at all sizes).
Run from the repository root: python3 tools/icon.py"""
import os
from PIL import Image, ImageDraw

BG, FG = (16, 21, 28, 255), (76, 195, 138, 255)
S = 2048  # draw big, scale down: no jagged edges


def draw(size, rounded=True, pad=0.0):
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if rounded:
        d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=BG)
    # The power symbol: an open ring and a bar, with round ends.
    c, r, w = S / 2, S * 0.27 * (1 - pad), S * 0.085 * (1 - pad)
    cy = c + S * 0.035
    d.arc([c - r, cy - r, c + r, cy + r], start=-50, end=230, fill=FG, width=int(w))
    import math
    for a in (-50, 230):  # round the ring's ends
        x = c + (r - w / 2) * math.cos(math.radians(a))
        y = cy + (r - w / 2) * math.sin(math.radians(a))
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=FG)
    top, bottom = cy - r - w * 0.35, cy - r * 0.18
    d.rounded_rectangle([c - w / 2, top, c + w / 2, bottom], radius=int(w / 2), fill=FG)
    return im.resize((size, size), Image.LANCZOS)


root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
win = os.path.join(root, 'windows-app')
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
draw(256).save(os.path.join(win, 'winres', 'icon.png'))
draw(256).save(os.path.join(win, 'icon.ico'), sizes=[(s, s) for s in sizes], append_images=[draw(s) for s in sizes])
os.makedirs(os.path.join(win, 'ui'), exist_ok=True)
for s in (32, 192, 512):
    draw(s).save(os.path.join(win, 'ui', f'icon-{s}.png'), optimize=True)

# Android launcher icons (legacy square-ish icons; Android 8+ uses the adaptive icon below).
res = os.path.join(root, 'android-app', 'android', 'app', 'src', 'main', 'res')
for name, s in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
    d = os.path.join(res, f'mipmap-{name}')
    os.makedirs(d, exist_ok=True)
    draw(s).save(os.path.join(d, 'ic_launcher.png'), optimize=True)
    # adaptive foreground: symbol only, inside the 66% safe zone of a 108dp canvas
    fg = Image.new('RGBA', (s * 108 // 48,) * 2, (0, 0, 0, 0))
    sym = draw(s * 108 // 48, rounded=False, pad=0.33)
    fg.alpha_composite(sym)
    fg.save(os.path.join(d, 'ic_launcher_foreground.png'), optimize=True)
os.makedirs(os.path.join(res, 'mipmap-anydpi-v26'), exist_ok=True)
open(os.path.join(res, 'mipmap-anydpi-v26', 'ic_launcher.xml'), 'w').write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
''')
vals = os.path.join(res, 'values')
os.makedirs(vals, exist_ok=True)
open(os.path.join(vals, 'ic_launcher_background.xml'), 'w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#10151C</color>
</resources>
''')
print('icons written')
