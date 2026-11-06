"""Draws the app's logo and every icon and graphic made from it.

Writes the Play Console icon and feature graphic to store/play-console/, and the
Android and iOS launcher icons into the app. Run from the project root:

    python3 tool/make_store_assets.py
"""

import os
import re

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(ROOT, 'store', 'play-console')

GREEN_LIGHT = (20, 150, 112)
GREEN_DARK = (8, 84, 64)
YELLOW = (255, 201, 40)
WHITE = (255, 255, 255)

# Drawn this many times larger, then scaled down, for smooth edges.
SUPERSAMPLE = 4

FONT_FILE = '/System/Library/Fonts/Avenir Next.ttc'


def gradient(size, start=GREEN_LIGHT, end=GREEN_DARK):
    """Diagonal gradient, light at the top left."""
    w, h = size
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(start, end))
    return small.resize((w, h), Image.BICUBIC)


def _scaled(points, box):
    x0, y0, size = box
    return [(x0 + x * size, y0 + y * size) for x, y in points]


# A navigation arrow, pointing up, in a unit square.
ARROW = [(0.5, 0.0), (0.92, 1.0), (0.5, 0.78), (0.08, 1.0)]

# A charging bolt in a unit square.
BOLT = [(0.62, 0.0), (0.1, 0.58), (0.46, 0.58), (0.34, 1.0), (0.9, 0.38), (0.54, 0.38)]


def draw_mark(img, cx, cy, size, bolt_color=YELLOW, arrow_color=WHITE, cut_bolt=False):
    """The logo mark: an arrow [size] tall centred on (cx, cy), with a bolt."""
    draw = ImageDraw.Draw(img)
    arrow_box = (cx - size / 2, cy - size / 2, size)
    draw.polygon(_scaled(ARROW, arrow_box), fill=arrow_color)
    bolt_size = size * 0.42
    bolt_box = (cx - bolt_size / 2, cy - bolt_size * 0.36, bolt_size)
    draw.polygon(_scaled(BOLT, bolt_box), fill=(0, 0, 0, 0) if cut_bolt else bolt_color)


def render(size, painter, mode='RGBA'):
    big = Image.new(mode, (size * SUPERSAMPLE, size * SUPERSAMPLE), (0, 0, 0, 0))
    painter(big, size * SUPERSAMPLE)
    return big.resize((size, size), Image.LANCZOS)


def full_icon(size):
    """Square, full bleed: stores and iOS round the corners themselves."""
    def paint(img, s):
        img.paste(gradient((s, s)), (0, 0))
        draw_mark(img, s / 2, s * 0.52, s * 0.6)
    return render(size, paint).convert('RGB')


def rounded_icon(size):
    """For Android launchers before adaptive icons: a rounded square."""
    def paint(img, s):
        mask = Image.new('L', (s, s), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=s * 0.22, fill=255)
        img.paste(gradient((s, s)), (0, 0), mask)
        draw_mark(img, s / 2, s * 0.52, s * 0.6)
    return render(size, paint)


def adaptive_foreground(size, monochrome=False):
    """108 dp layer. Launchers show the middle 66 dp, so the mark stays inside it."""
    def paint(img, s):
        if monochrome:
            draw_mark(img, s / 2, s * 0.51, s * 0.42, cut_bolt=True)
        else:
            draw_mark(img, s / 2, s * 0.51, s * 0.42)
    return render(size, paint)


def adaptive_background(size):
    return gradient((size, size))


def feature_graphic():
    """1024 x 500, no transparency, as Play requires."""
    w, h = 1024, 500
    s = SUPERSAMPLE
    img = gradient((w * s, h * s)).convert('RGBA')

    # See-through parts go on their own layer: drawing them straight onto the
    # image would replace the pixels underneath instead of blending.
    overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
    layer = ImageDraw.Draw(overlay)
    route = [(-40 * s, 470 * s), (260 * s, 430 * s), (560 * s, 470 * s), (820 * s, 400 * s), (1080 * s, 420 * s)]
    layer.line(route, fill=(255, 255, 255, 30), width=22 * s, joint='curve')

    small = ImageFont.truetype(FONT_FILE, 25 * s, index=2)  # Avenir Next Demi Bold
    chips = []
    x = 420 * s
    chip_y = 330 * s
    for label in ['Smart stops', '180 kW first', 'Live battery']:
        tw = layer.textlength(label, font=small)
        box = (x, chip_y, x + tw + 36 * s, chip_y + 46 * s)
        layer.rounded_rectangle(box, radius=23 * s, fill=(255, 255, 255, 38), outline=(255, 255, 255, 110), width=2 * s)
        chips.append((label, x + 18 * s, chip_y + 7 * s))
        x = box[2] + 14 * s
    img.alpha_composite(overlay)

    icon = rounded_icon(300).resize((300 * s, 300 * s), Image.LANCZOS)
    shadow = Image.new('RGBA', icon.size, (0, 0, 0, 0))
    shadow.putalpha(icon.split()[3].point(lambda a: a * 0.35))
    shadow = shadow.filter(ImageFilter.GaussianBlur(16 * s))
    img.alpha_composite(shadow, (72 * s, 112 * s))
    img.alpha_composite(icon, (72 * s, 100 * s))

    draw = ImageDraw.Draw(img)
    title = ImageFont.truetype(FONT_FILE, 74 * s, index=0)  # Avenir Next Bold
    body = ImageFont.truetype(FONT_FILE, 33 * s, index=5)  # Avenir Next Medium
    draw.text((420 * s, 118 * s), 'Vinfast Copilot', font=title, fill=WHITE)
    draw.text((420 * s, 214 * s), 'EV road trips across India,', font=body, fill=(230, 245, 239))
    draw.text((420 * s, 258 * s), 'with live charger checks.', font=body, fill=(230, 245, 239))
    for label, lx, ly in chips:
        draw.text((lx, ly), label, font=small, fill=WHITE)
    return img.resize((w, h), Image.LANCZOS).convert('RGB')


def save(img, *parts):
    path = os.path.join(*parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    return path


def android_icons():
    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for name, scale in densities.items():
        folder = os.path.join(res, f'mipmap-{name}')
        save(rounded_icon(round(48 * scale)), folder, 'ic_launcher.png')
        layer = round(108 * scale)
        save(adaptive_foreground(layer), folder, 'ic_launcher_foreground.png')
        save(adaptive_foreground(layer, monochrome=True), folder, 'ic_launcher_monochrome.png')
        save(adaptive_background(layer), folder, 'ic_launcher_background.png')
    anydpi = os.path.join(res, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
                '</adaptive-icon>\n')


def ios_icons():
    folder = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    master = full_icon(1024)
    for name in os.listdir(folder):
        m = re.match(r'Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$', name)
        if not m:
            continue
        px = round(float(m.group(1)) * int(m.group(2)))
        master.resize((px, px), Image.LANCZOS).save(os.path.join(folder, name), optimize=True)


# Captions for the phone screenshots, by file name. Kept to what the app does.
CAPTIONS = {
    '01-setup': ('Set up your car once', 'Battery, consumption, rated range and drag shape every estimate'),
    '02-destination': ('Search anywhere in India', 'Places autocomplete from Google Maps'),
    '03-route-plan': ('Every charging stop, planned', 'Fast and free chargers first, arriving with 55%'),
    '04-guidance': ('Turn-by-turn, with a live battery', 'Measured from your real speed, stops and weather'),
    '05-chargers': ('Chargers ranked for you', 'Status where networks report it, guns free, charge time, food nearby'),
    '06-heading-to-charger': ('Know your stop before you arrive', 'Charge on arrival and the total time to 80%'),
}


def wrap(draw, text, font, width):
    lines, line = [], ''
    for word in text.split():
        trial = f'{line} {word}'.strip()
        if draw.textlength(trial, font=font) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    return lines


def captioned_screenshot(raw_path, title, subtitle):
    """1080 x 1920: a caption on the brand gradient above the screenshot."""
    w, h = 1080, 1920
    img = gradient((w, h)).convert('RGBA')
    draw = ImageDraw.Draw(img)
    title_font = ImageFont.truetype(FONT_FILE, 68, index=0)
    body_font = ImageFont.truetype(FONT_FILE, 38, index=5)
    y = 90
    for line in wrap(draw, title, title_font, w - 120):
        draw.text((w / 2, y), line, font=title_font, fill=WHITE, anchor='ma')
        y += 84
    y += 10
    for line in wrap(draw, subtitle, body_font, w - 160):
        draw.text((w / 2, y), line, font=body_font, fill=(225, 243, 236), anchor='ma')
        y += 52

    shot = Image.open(raw_path).convert('RGB')
    top = max(y + 50, 400)
    shot_h = h - top - 70
    shot_w = round(shot.width * shot_h / shot.height)
    shot = shot.resize((shot_w, shot_h), Image.LANCZOS)
    radius = 44
    mask = Image.new('L', shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot_w - 1, shot_h - 1), radius=radius, fill=255)
    x = (w - shot_w) // 2
    shadow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 12, x + shot_w, top + 12 + shot_h), radius=radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))
    img.paste(shot, (x, top), mask)
    return img.convert('RGB')


def screenshots():
    raw = os.path.join(STORE, 'screenshots', 'phone', 'raw')
    if not os.path.isdir(raw):
        return
    for name in sorted(os.listdir(raw)):
        key = os.path.splitext(name)[0]
        if key in CAPTIONS:
            save(captioned_screenshot(os.path.join(raw, name), *CAPTIONS[key]),
                 STORE, 'screenshots', 'phone', 'captioned', name)


def main():
    save(full_icon(512), STORE, 'icon', 'app-icon-512.png')
    save(full_icon(1024), STORE, 'icon', 'app-icon-1024.png')
    save(feature_graphic(), STORE, 'feature-graphic', 'feature-graphic-1024x500.png')
    android_icons()
    ios_icons()
    screenshots()
    print('Wrote', STORE, 'and the launcher icons')


if __name__ == '__main__':
    main()
