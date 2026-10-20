"""Sync the String Catalogs with the code and refuse an incomplete localization.

Package.swift compiles the app with `-emit-localized-strings`, so the compiler
writes one .stringsdata file per source file listing every localizable string it
type-checked (SwiftUI text, String(localized:), LocalizedStringKey). This script
merges the files of the current sources into Resources/Localizable.xcstrings
with `xcstringstool sync`, as Xcode does on every build, and then fails when the
catalogs are not ready to ship:

- a string the code no longer uses (stale), unless --prune-stale removes it;
- a string missing a language, or not marked translated, in any language the
  catalogs carry;
- a translation whose format specifiers differ from the English text's, which
  would print the wrong argument or crash;
- an InfoPlist.xcstrings English value that differs from Resources/Info.plist.

Run (build.sh does): python3 -I scripts/sync-strings.py .build/localized-strings
Runs on the system Python 3.9 as well, so it uses the standard library only.
"""

from __future__ import annotations

import argparse
import json
import logging
import plistlib
import re
import subprocess
import sys
from pathlib import Path

log = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "TranslateLikeMe"
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
INFO_CATALOG = ROOT / "Resources" / "InfoPlist.xcstrings"
INFO_PLIST = ROOT / "Resources" / "Info.plist"

# printf-style specifiers as Foundation formats them: an optional position, flags,
# width, precision, a length modifier and the conversion; "%%" is a literal.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])")


def specifiers(text: str) -> list[tuple[int, str]]:
    """The arguments a format string reads, as (position, type), sorted."""
    found = []
    implicit = 0
    for match in SPECIFIER.finditer(text):
        position, length, conversion = match.groups()
        if conversion == "%":
            continue
        implicit += 1
        found.append((int(position) if position else implicit, (length or "") + conversion))
    return sorted(found)


def string_units(localization: dict) -> list[tuple[str, dict]]:
    """Every stringUnit of one language, plural and device variations included."""
    units = []
    if "stringUnit" in localization:
        units.append(("", localization["stringUnit"]))
    for kind, forms in localization.get("variations", {}).items():
        for form, value in forms.items():
            units += [(f"{kind}.{form}{name}", unit) for name, unit in string_units(value)]
    return units


def stringsdata_files(directory: Path) -> list[Path]:
    """The .stringsdata file of each current source file, matched by the `source`
    it records, so one left by a deleted source file is not synced."""
    by_source = {}
    for path in directory.glob("*.stringsdata"):
        source = json.loads(path.read_text()).get("source", "")
        by_source[Path(source).resolve()] = path
    sources = sorted(SOURCES.glob("*.swift"))
    missing = [source.name for source in sources if source.resolve() not in by_source]
    if missing:
        log.error("No .stringsdata for %s in %s, emptied after its build? Run `swift package clean`, "
                  "then build again.", ", ".join(missing), directory)
        sys.exit(1)
    return [by_source[source.resolve()] for source in sources]


def prune_stale(catalog: Path) -> None:
    data = json.loads(catalog.read_text())
    stale = [key for key, entry in data["strings"].items() if entry.get("extractionState") == "stale"]
    for key in stale:
        log.info("Removed stale string %r", key)
        del data["strings"][key]
    if stale:
        # The layout xcstringstool writes, so the next sync leaves the file alone.
        catalog.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : ")))


def problems(catalog: Path, plist: dict | None = None) -> list[str]:
    data = json.loads(catalog.read_text())
    source = data["sourceLanguage"]
    strings = data["strings"]
    languages = sorted({lang for entry in strings.values() for lang in entry.get("localizations", {})} - {source})
    found = []
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        if entry.get("extractionState") == "stale":
            found.append(f"{key!r} is no longer in the code: remove it (--prune-stale)")
            continue
        localizations = entry.get("localizations", {})
        english = localizations.get(source, {}).get("stringUnit", {}).get("value", key)
        if plist is not None and plist.get(key) != english:
            found.append(f"{key!r}: English {english!r} differs from Info.plist {plist.get(key)!r}")
        expected = specifiers(english)
        for lang in languages:
            if lang not in localizations:
                found.append(f"{key!r} has no {lang} translation")
                continue
            for form, unit in string_units(localizations[lang]):
                where = f"{key!r} [{lang}{' ' + form if form else ''}]"
                if unit.get("state") != "translated":
                    found.append(f"{where} is {unit.get('state')!r}, not translated")
                if specifiers(unit.get("value", "")) != expected:
                    found.append(f"{where} has format specifiers {unit.get('value')!r} unlike the English {english!r}")
    return [f"{catalog.name}: {problem}" for problem in found]


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("stringsdata", type=Path, help="the -emit-localized-strings-path directory")
    parser.add_argument("--prune-stale", action="store_true", help="remove strings the code no longer uses")
    args = parser.parse_args()

    files = stringsdata_files(args.stringsdata)
    command = ["xcrun", "xcstringstool", "sync", str(CATALOG)]
    for path in files:
        command += ["--stringsdata", str(path)]
    subprocess.run(command, check=True)
    if args.prune_stale:
        prune_stale(CATALOG)

    found = problems(CATALOG) + problems(INFO_CATALOG, plistlib.loads(INFO_PLIST.read_bytes()))
    for problem in found:
        log.error("%s", problem)
    if found:
        log.error("%d localization problem(s); every string ships in every language (CLAUDE.md, Localization).",
                  len(found))
        sys.exit(1)


if __name__ == "__main__":
    main()
