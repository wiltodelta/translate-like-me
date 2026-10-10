# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools"]
# ///
"""Rebuild the Icon Composer icon (Resources/AppIcon.icon) as flat vector layers.

The system draws Liquid Glass per layer, and macOS 27 gives each layer its own
glass, so every feature is its own flat SVG without painted shading: brows,
eye whites, pupils, the symbol plate and the "@!%$" symbols. The shapes are
drawn from the measurements of the original round artwork; the symbols are set
in Nunito ExtraBold, the typeface the original used, vendored as a subset under
scripts/fonts. The orange-to-pink head gradient is the icon's background fill.
Colors and the dark-appearance variants live in icon.json, which this script
writes too. build.sh compiles the .icon with actool.

It then renders Resources/appicon_1024.png from the icon with Icon Composer's
ictool (the default appearance, macOS 27 design), the raster the website's
icons and link preview are made from, so they show the icon the app ships.

Run: uv run scripts/make-icon-layers.py
"""

import json
import logging
import subprocess
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

log = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parent.parent
FONT = ROOT / "scripts" / "fonts" / "Nunito-ExtraBold-symbols.ttf"  # OFL, subset to the symbols
ICON = ROOT / "Resources" / "AppIcon.icon"
RASTER = ROOT / "Resources" / "appicon_1024.png"
ICTOOL = Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")
ASSETS = ICON / "Assets"

SIZE = 1024

# Layer geometry in the 1024-point layer space, measured on the features of the
# original round artwork (appicon_1024.png until 3.3) as the earlier raster layer
# placed them (the brow curve fitted to 98.6% overlap). Brows mirror around the face's axis.
AXIS_X = 507.25
EYES = [(340, 419.5), (674.5, 419.5)]
EYE_RADIUS = 137.5
PUPIL_RADIUS = 73
BROW = [(276.7, 246.8), (320, 229.7), (400.5, 220.8), (472, 296.3)]  # cubic, left brow
BROW_WIDTH = 50.3
PLATE = (112, 581, 799, 272, 34)  # x, y, width, height, corner radius
SYMBOLS = "@!%$"
SYMBOL_BOX = (207, 610, 812, 830)  # the original symbols' extent on the plate

BACKGROUND = ["extended-srgb:0.98039,0.70588,0.46667,1.00000",
              "extended-srgb:0.97255,0.18824,0.56471,1.00000"]
BROW_COLOR = "srgb:0.14118,0.09020,0.15686,1.00000"
PUPIL_COLOR = "srgb:0.25490,0.19608,0.29804,1.00000"
WHITE = "srgb:0.94902,0.94902,0.94902,1.00000"
PLATE_COLOR = "srgb:0.21961,0.14510,0.23137,1.00000"


def symbols_path() -> str:
    """Set "@!%$" in Nunito ExtraBold, the original's typeface, inside its box."""
    font = TTFont(FONT)
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    advance = 0.0
    placed = []
    for char in SYMBOLS:
        name = cmap[ord(char)]
        bounds = BoundsPen(glyphs)
        glyphs[name].draw(bounds)
        placed.append((name, advance, bounds.bounds))
        advance += glyphs[name].width
    left = min(b[0] + x for _, x, b in placed)
    right = max(b[2] + x for _, x, b in placed)
    bottom = min(b[1] for _, _, b in placed)
    top = max(b[3] for _, _, b in placed)
    x0, y0, x1, y1 = SYMBOL_BOX
    scale = (x1 - x0) / (right - left)
    # Font units grow upward; centre the run vertically in the box.
    shift_y = (y0 + y1) / 2 + (top + bottom) / 2 * scale
    paths = []
    for name, x, _ in placed:
        pen = SVGPathPen(glyphs, lambda value: f"{value:.1f}")
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x0 + (x - left) * scale, shift_y)))
        paths.append(pen.getCommands())
    return "".join(paths)


def svg(body: str) -> str:
    # Shapes are white; icon.json gives each layer its color.
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
            f'viewBox="0 0 {SIZE} {SIZE}">{body}</svg>\n')


def brow_path(points: list[tuple[float, float]]) -> str:
    (ax, ay), (bx, by), (cx, cy), (dx, dy) = points
    return (f'<path d="M{ax},{ay} C{bx},{by} {cx},{cy} {dx},{dy}" fill="none" '
            f'stroke="#fff" stroke-width="{BROW_WIDTH}" stroke-linecap="round"/>')


def circles(radius: float) -> str:
    return "".join(f'<circle cx="{x}" cy="{y}" r="{radius}" fill="#fff"/>' for x, y in EYES)


def layer(name: str, fill: str, dark: str | None = None, glass: bool = True) -> dict:
    # The dark appearance repaints white layers with the background gradient
    # unless the layer names its dark fill, and the eyes stay white in every look.
    # A distinct dark fill (the brows, which vanish on dark fills) holds when tinted too.
    fills = [{"value": {"solid": fill}}, {"appearance": "dark", "value": {"solid": dark or fill}}]
    if dark:
        fills.append({"appearance": "tinted", "value": {"solid": dark}})
    return {"fill-specializations": fills, "glass": glass, "image-name": f"{name}.svg", "name": name}


def group(*layers: dict) -> dict:
    return {"layers": list(layers), "lighting": "individual",
            "shadow": {"kind": "neutral", "opacity": 0.5}, "specular": True,
            "translucency": {"enabled": False, "value": 0.5}}


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    mirrored = [(round(2 * AXIS_X - x, 2), y) for x, y in BROW]
    x, y, width, height, radius = PLATE
    shapes = {
        "brows": brow_path(BROW) + brow_path(mirrored),
        "pupils": circles(PUPIL_RADIUS),
        "eyes": circles(EYE_RADIUS),
        "symbols": f'<path d="{symbols_path()}" fill="#fff"/>',
        "plate": f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="{radius}" fill="#fff"/>',
    }
    for stale in ASSETS.iterdir():
        stale.unlink()
    for name, body in shapes.items():
        (ASSETS / f"{name}.svg").write_text(svg(body))
    # Groups and layers run top to bottom.
    document = {
        "fill": {"linear-gradient": BACKGROUND},
        "groups": [
            group(layer("brows", BROW_COLOR, dark=WHITE)),
            # Pupils and symbols are printed on their glass: as glass themselves
            # each got a rim (a gray ring, a dark halo) the original never had.
            group(layer("pupils", PUPIL_COLOR, glass=False), layer("eyes", WHITE)),
            group(layer("symbols", WHITE, glass=False), layer("plate", PLATE_COLOR)),
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (ICON / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
    log.info("Wrote %s with %s layers", ICON.relative_to(ROOT), len(shapes))
    subprocess.run([ICTOOL, ICON, "--export-image", "--output-file", RASTER, "--platform", "macOS",
                    "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1",
                    "--design-generation", "27"], check=True, capture_output=True)
    log.info("Rendered %s", RASTER.relative_to(ROOT))


if __name__ == "__main__":
    main()
