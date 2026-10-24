# /// script
# requires-python = ">=3.11"
# ///
"""Rebuild the Icon Composer icon (Resources/AppIcon.icon) as flat vector layers.

The system draws Liquid Glass per layer, and macOS 27 gives each layer its own
glass, so every feature is its own flat SVG without painted shading: brows, eye
whites, pupils and the open smiling mouth. The orange-to-pink head gradient is
the icon's background fill. Colors and the dark-appearance variants live in icon.json, which this
script writes too. build.sh compiles the .icon with actool.

It then renders Resources/appicon_1024.png from the icon with Icon Composer's
ictool (the default appearance, macOS 27 design), the raster Victor's
personal website takes the product icon from, so it shows the icon the app ships.

Run: uv run scripts/make-icon-layers.py
"""

import json
import logging
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "Resources" / "AppIcon.icon"
RASTER = ROOT / "Resources" / "appicon_1024.png"
ICTOOL = Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")
ASSETS = ICON / "Assets"

SIZE = 1024

# Layer geometry in the 1024-point layer space. The eye whites keep the size
# measured on the original round artwork (appicon_1024.png until 3.3), raised to
# make room for the mouth. Brows mirror around the face's axis.
AXIS_X = 507.25
EYES = [(340, 400), (674.5, 400)]
EYE_RADIUS = 137.5
PUPIL_RADIUS = 73
BROW = [(240, 200), (285, 150), (395, 150), (440, 200)]  # cubic, left brow, arching up
BROW_WIDTH = 50
MOUTH = (272, 742, 600, 850)  # left, right, top corners' y, bottom
MOUTH_SAG = 40  # the top edge's dip at the middle
MOUTH_SHOULDER = 0.75  # where the sides start curving in, as a share of the depth
MOUTH_ROUNDNESS = 0.55  # the bottom's control points, as a share of the half width

BACKGROUND = ["extended-srgb:0.98039,0.70588,0.46667,1.00000",
              "extended-srgb:0.97255,0.18824,0.56471,1.00000"]
BROW_COLOR = "srgb:0.14118,0.09020,0.15686,1.00000"
PUPIL_COLOR = "srgb:0.25490,0.19608,0.29804,1.00000"
WHITE = "srgb:0.94902,0.94902,0.94902,1.00000"
MOUTH_COLOR = "srgb:0.21961,0.14510,0.23137,1.00000"


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


def mouth() -> str:
    """An open smile: a top edge sagging slightly, a deep round bottom."""
    left, right, top, bottom = MOUTH
    middle, half = (left + right) / 2, (right - left) / 2
    shoulder = top + (bottom - top) * MOUTH_SHOULDER
    return (f'<path d="M{left},{top} Q{middle},{top + MOUTH_SAG} {right},{top} '
            f'C{right},{shoulder} {middle + half * MOUTH_ROUNDNESS},{bottom} {middle},{bottom} '
            f'C{middle - half * MOUTH_ROUNDNESS},{bottom} {left},{shoulder} {left},{top} Z" fill="#fff"/>')


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
    shapes = {
        "brows": brow_path(BROW) + brow_path(mirrored),
        "pupils": circles(PUPIL_RADIUS),
        "eyes": circles(EYE_RADIUS),
        "mouth": mouth(),
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
            # Pupils are printed on their glass: as glass themselves they got a
            # gray rim the original never had.
            group(layer("pupils", PUPIL_COLOR, glass=False), layer("eyes", WHITE)),
            group(layer("mouth", MOUTH_COLOR)),
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
