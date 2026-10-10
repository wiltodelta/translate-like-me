# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Draw the menu bar template images, Resources/MenuBarIcon.png (idle) and
Resources/MenuBarBusy.png (a translation runs).

The glyph is the app icon's face reduced to 18 pt: a rounded tile with angry
brows, eyes and the symbol plate as a bar. Idle it is an outline; busy it is a
solid tile with the features cut out, the outline / .fill pairing SF Symbols
uses and that Rota and Watch Me While I Fall Asleep follow, so the three read as
one family in the menu bar. Shapes are drawn at 1024 and downsampled, so the
edges are antialiased; only the alpha channel matters to a template image.

Run: uv run scripts/make-menubar-icons.py
"""

import logging
from pathlib import Path

from PIL import Image, ImageDraw

log = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parent.parent
CANVAS = 1024
PIXELS = 72  # 18 pt at 4x; App.swift sizes the image to 18 pt

# Drawn for 18 pt rather than taken from make-icon-layers.py: the app icon's
# curved brows and small pupils do not survive the reduction.
TILE = (70, 70, 954, 954)
TILE_RADIUS, TILE_STROKE = 250, 84
BROWS = [((285, 282), (455, 338)), ((739, 282), (569, 338))]  # outer end to inner end, slanting down
BROW_WIDTH = 60
EYES = [(372, 470), (652, 470)]
EYE_RADIUS = 92
MOUTH = (300, 640, 724, 736)  # the symbol plate


def glyph(busy: bool) -> Image.Image:
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(TILE, TILE_RADIUS, fill=255)
    if busy:
        ink = 0  # the features are holes in a solid tile
    else:
        x0, y0, x1, y1 = TILE
        draw.rounded_rectangle((x0 + TILE_STROKE, y0 + TILE_STROKE, x1 - TILE_STROKE, y1 - TILE_STROKE),
                               TILE_RADIUS - TILE_STROKE, fill=0)
        ink = 255
    half = BROW_WIDTH / 2
    for start, end in BROWS:
        draw.line((*start, *end), fill=ink, width=BROW_WIDTH)
        for x, y in (start, end):
            draw.ellipse((x - half, y - half, x + half, y + half), fill=ink)
    for x, y in EYES:
        draw.ellipse((x - EYE_RADIUS, y - EYE_RADIUS, x + EYE_RADIUS, y + EYE_RADIUS), fill=ink)
    draw.rounded_rectangle(MOUTH, (MOUTH[3] - MOUTH[1]) / 2, fill=ink)
    image = Image.new("RGBA", (PIXELS, PIXELS), (0, 0, 0, 0))
    image.putalpha(mask.resize((PIXELS, PIXELS), Image.LANCZOS))
    return image


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    for name, busy in (("MenuBarIcon", False), ("MenuBarBusy", True)):
        path = ROOT / "Resources" / f"{name}.png"
        glyph(busy).save(path)
        log.info("Wrote %s", path.relative_to(ROOT))


if __name__ == "__main__":
    main()
