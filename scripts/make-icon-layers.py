# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Rebuild the Icon Composer foreground layer from the original round artwork.

macOS 26+ masks app icons itself and puts a non-conforming (round) icon inside a
gray plate, so the HIG asks for square, unmasked layers. This splits
Resources/appicon_1024.png into the features (brows, eyes, symbol plate), which
become Resources/AppIcon.icon/Assets/face.png; the orange-to-pink head gradient
becomes the icon's background fill in AppIcon.icon/icon.json. build.sh compiles
the .icon with actool.

Run: uv run scripts/make-icon-layers.py
"""

import colorsys
import logging
import math
from pathlib import Path

from PIL import Image

log = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "appicon_1024.png"
LAYER = ROOT / "Resources" / "AppIcon.icon" / "Assets" / "face.png"

SIZE = 1024
HEAD_RADIUS = 470  # beyond this only the round head's rim remains
PLATE = (80, 612, 945, 912)  # the symbol plate reaches past the head's circle
WIDTH_SHARE = 0.78  # the plate spans this share of the square layer


def clamp(value: float) -> float:
    return max(0.0, min(1.0, value))


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    source = Image.open(SOURCE).convert("RGBA")
    pixels = source.load()
    features = Image.new("RGBA", source.size, (0, 0, 0, 0))
    out = features.load()
    x0, y0, x1, y1 = PLATE
    for y in range(source.height):
        for x in range(source.width):
            r, g, b, a = pixels[x, y]
            in_plate = x0 <= x <= x1 and y0 <= y <= y1
            if a < 8 or (math.hypot(x - SIZE / 2, y - SIZE / 2) > HEAD_RADIUS and not in_plate):
                continue
            _, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            # Features are white (low saturation) or dark (low value); the head
            # gradient is saturated and bright.
            feature = max(clamp((0.22 - s) / 0.12), clamp((0.48 - v) / 0.15))
            alpha = int(255 * feature * a / 255)
            if alpha >= 40:
                out[x, y] = (r, g, b, alpha)
    core = features.crop(features.getbbox())
    scale = WIDTH_SHARE * SIZE / core.width
    core = core.resize((round(core.width * scale), round(core.height * scale)), Image.LANCZOS)
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    layer.alpha_composite(core, ((SIZE - core.width) // 2, (SIZE - core.height) // 2 + 20))
    layer.save(LAYER)
    log.info("Wrote %s (features %sx%s)", LAYER.relative_to(ROOT), core.width, core.height)


if __name__ == "__main__":
    main()
