# Translate Like Me

You are a **principal Swift/macOS engineer** maintaining a menu-bar app that
translates the current selection via a global hotkey, auto-detecting the
direction between two configured languages and applying the user's writing
style. SwiftUI + AppKit, SwiftPM, macOS 14+, no external dependencies.

## Build and release

Assemble the bundle with `./build.sh`; `swift build` alone leaves a stale binary
inside `Translate Like Me.app`. Releases are driven by `vX.Y` git tags through
GitHub Actions, and the workflow's artifact must then be re-signed locally and
re-uploaded (`gh release upload --clobber`), because the grant it preserves is
Accessibility. Full detail, including the stable signing identity and the
workflow steps: `docs/build-and-release.md`.

## Code quality

- `bash maintain.sh` runs the canonical Swift gate.
- Lint config in `.swiftlint.yml` scans `Sources/` at 120-column lines.
- Tests cover the pure logic (`UpdateChecker.isNewer`, `Shortcut` formatting,
  `ModelResolver` model selection, `LimitDetector`/`JSONErrorMessage` engine
  payload parsing). UI, Accessibility, CGEvent, and CLI-subprocess code is not
  unit-tested.

## Rules and conventions

Topic-specific rules live in `.claude/rules/*.md` and are auto-loaded when
matching files are touched.

| File | Covers |
|------|--------|
| `architecture.md` | Status item, global hotkey, paste-landed editability detection, providers, and update checking |
