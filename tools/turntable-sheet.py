#!/usr/bin/env python3
"""Generate the turntable tracking sheet.

Writes the reference image bundled in the iPhone app (ARKit image tracking) and a
Letter PDF that prints it at exactly SIZE_MM. The app's physicalWidth must equal SIZE_MM.
Deterministic: same seed, same pattern. Black and white so laser printers reproduce it.
"""
import random
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

SIZE_MM = 180
PX = 2048
SEED = 3141
ROOT = Path(__file__).resolve().parents[1]
APP_PNG = ROOT / "apps/house-capture/HouseCapture/TurntableSheet.png"
PDF = ROOT / "apps/house-capture/release/turntable-sheet.pdf"


def pattern() -> Image.Image:
    rnd = random.Random(SEED)
    img = Image.new("L", (PX, PX), 255)
    d = ImageDraw.Draw(img)
    for _ in range(900):
        x, y = rnd.uniform(0, PX), rnd.uniform(0, PX)
        s = rnd.uniform(14, 120)
        fill = 0 if rnd.random() < 0.75 else 255
        kind = rnd.random()
        if kind < 0.4:
            d.ellipse([x, y, x + s, y + s * rnd.uniform(0.4, 1)], fill=fill)
        elif kind < 0.75:
            d.polygon([(x + rnd.uniform(-s, s), y + rnd.uniform(-s, s)) for _ in range(3)], fill=fill)
        else:
            d.rectangle([x, y, x + s, y + s * rnd.uniform(0.2, 1)], fill=fill)
    # placement target for the object
    c, r = PX / 2, PX * 0.12
    d.ellipse([c - r, c - r, c + r, c + r], outline=0, width=10)
    d.ellipse([c - r + 14, c - r + 14, c + r - 14, c + r - 14], outline=255, width=8)
    # border keeps the edge crisp
    d.rectangle([0, 0, PX - 1, PX - 1], outline=0, width=24)
    return img


def pdf(img: Image.Image):
    dpi = 300
    page = Image.new("L", (int(8.5 * dpi), 11 * dpi), 255)
    side = round(SIZE_MM / 25.4 * dpi)
    left, top = (page.width - side) // 2, round(0.75 * dpi)
    page.paste(img.resize((side, side), Image.LANCZOS), (left, top))
    d = ImageDraw.Draw(page)
    font = ImageFont.load_default(size=40)
    y = top + side + 80
    bar = round(100 / 25.4 * dpi)
    d.rectangle([left, y, left + bar, y + 24], fill=0)
    d.text((left, y + 40), "This bar must measure exactly 100 mm. If not, reprint at 100% / Actual size.", fill=0, font=font)
    d.text((left, y + 100), f"3D Model Anything turntable sheet · {SIZE_MM} mm square · put the object in the circle,", fill=0, font=font)
    d.text((left, y + 150), "set the sheet on a plate or board, and turn the board, not the object.", fill=0, font=font)
    PDF.parent.mkdir(parents=True, exist_ok=True)
    page.save(PDF, resolution=dpi)


if __name__ == "__main__":
    img = pattern()
    img.save(APP_PNG, optimize=True)
    pdf(img)
    print(APP_PNG, PDF)
