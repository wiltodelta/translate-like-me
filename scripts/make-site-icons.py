# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Write the website's icons from the app icon into a site directory.

favicon.ico (16, 32, 48), icon-256.png (the page header and browsers, sharp
at 2x) and apple-touch-icon.png (180), so nothing downloads the 1024px
original. The Pages workflow runs it at deploy time, so the icons always follow
Resources/appicon_1024.png and none is committed.

Run: uv run scripts/make-site-icons.py <site directory>
"""

import logging
import sys
from pathlib import Path

from PIL import Image

log = logging.getLogger(__name__)

ICON = Path(__file__).resolve().parent.parent / "Resources" / "appicon_1024.png"


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    out = Path(sys.argv[1])
    icon = Image.open(ICON).convert("RGBA")
    icon.save(out / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
    log.info("Wrote %s", out / "favicon.ico")
    for name, size in (("icon-256.png", 256), ("apple-touch-icon.png", 180)):
        icon.resize((size, size), Image.Resampling.LANCZOS).save(
            out / name, optimize=True
        )
        log.info("Wrote %s", out / name)


if __name__ == "__main__":
    main()
