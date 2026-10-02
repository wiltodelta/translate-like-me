# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Build the website's link preview image, site/og-image.png (1200x630).

Social networks and chat apps crop a link preview to about 1.91:1, so the
portrait screenshots cut badly there. This lays out the app icon, the name and
the tagline beside the menu screenshot (screenshots/menu.png).
capture-screenshots.sh runs it after every capture, so the preview never shows
an older menu. Needs macOS for the San Francisco font.

Run: uv run scripts/make-og-image.py
"""

import logging
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

log = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "Resources" / "appicon_1024.png"
MENU = ROOT / "screenshots" / "menu.png"
OUT = ROOT / "site" / "og-image.png"
FONT = Path("/System/Library/Fonts/SFNS.ttf")

WIDTH, HEIGHT = 1200, 630
MARGIN = 64
MENU_MARGIN = 56  # above and below the screenshot
ICON_SIZE = 128
GAP = 24  # at least this much between the text and the screenshot
CORNER = 20  # the screenshot reads as a card rather than a gray box
# The website's light theme: --card, --fg and --muted in site/index.html.
BACKGROUND = (245, 245, 247)
TEXT = (29, 29, 31)
MUTED = (81, 81, 84)

TITLE = "Translate Like Me"
TAGLINE = ["Translate selected text", "in any Mac app, in your", "own writing style"]
NOTE = "Free and open source. Claude, ChatGPT or Grok."


def font(size: int, weight: str) -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(str(FONT), size)
    face.set_variation_by_name(weight)
    return face


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    canvas = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(canvas)

    menu = Image.open(MENU).convert("RGBA")
    menu_height = HEIGHT - 2 * MENU_MARGIN
    menu = menu.resize(
        (round(menu.width * menu_height / menu.height), menu_height),
        Image.Resampling.LANCZOS,
    )
    mask = Image.new("L", menu.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *menu.size), CORNER, fill=255)
    menu_left = WIDTH - MARGIN - menu.width
    canvas.paste(menu, (menu_left, (HEIGHT - menu.height) // 2), mask)

    icon_top = 84
    icon = (
        Image.open(ICON)
        .convert("RGBA")
        .resize((ICON_SIZE, ICON_SIZE), Image.Resampling.LANCZOS)
    )
    canvas.paste(icon, (MARGIN, icon_top), icon)

    # Each line is (text, font, color, space after it); a wider gap sets the
    # note apart from the tagline.
    tagline = font(34, "Regular")
    lines = [(TITLE, font(60, "Bold"), TEXT, 92)]
    lines += [(line, tagline, MUTED, 46) for line in TAGLINE[:-1]]
    lines += [(TAGLINE[-1], tagline, MUTED, 80), (NOTE, font(24, "Medium"), MUTED, 0)]
    y = icon_top + ICON_SIZE + GAP
    for text, face, fill, after in lines:
        draw.text((MARGIN, y), text, font=face, fill=fill)
        right = draw.textbbox((MARGIN, y), text, font=face)[2]
        if right > menu_left - GAP:
            raise SystemExit(
                f"{text!r} reaches x={right}, within {GAP}px of the screenshot"
            )
        y += after

    canvas.save(OUT, optimize=True)
    log.info("Wrote %s (%dx%d)", OUT.relative_to(ROOT), WIDTH, HEIGHT)


if __name__ == "__main__":
    main()
