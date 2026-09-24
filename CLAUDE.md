# Translate Like Me

You are a **principal Swift/macOS engineer** maintaining a menu-bar app that
translates the current selection via a global hotkey, auto-detecting the
direction between two configured languages and applying the user's writing
style. SwiftUI + AppKit, SwiftPM, no external dependencies. Supports the three
latest macOS releases (15+) on Apple silicon only.

## Build and release

Assemble the bundle with `./build.sh` (needs Xcode 26+: `actool` compiles the
Icon Composer icon); `swift build` alone leaves a stale binary inside
`Translate Like Me.app`. Releases are driven by `vX.Y` git tags through
GitHub Actions, which signs with the Developer ID from repository secrets and
notarizes (`notarize.sh`); locally `build.sh` signs with the same identity from
the keychain. Full detail, including the secrets and where the keys are kept
(1Password): `docs/build-and-release.md`.

## Code quality

- `bash maintain.sh` runs the canonical Swift gate.
- Lint config in `.swiftlint.yml` scans `Sources/` at 120-column lines.
- Tests cover the pure logic (`UpdateChecker.isNewer`, `Shortcut` formatting and
  menu key equivalents, `Languages` pair editing, defaults from the macOS
  languages and migration from the single pair, the pair prompt,
  `HarnessDefaults` config reading, `HarnessModels` catalog parsing (claude,
  codex, grok) and `HarnessChoice`, the settings model/effort pick,
  `ModelResolver` API model selection, `LimitDetector` and `JSONErrorMessage`
  engine payload parsing). UI, Accessibility, CGEvent, and CLI-subprocess code
  is not unit-tested; render UI changes with
  `./capture-screenshots.sh` (it also regenerates `screenshots/`; needs
  Accessibility and Screen Recording for the terminal and a Mac left alone).
- Live runs of a dev build read and write the installed app's settings domain
  (`com.wiltodelta.translatelikeme`): save and restore any key a test changes,
  or override it for one launch without writing (`open -n "Translate Like
  Me.app" --args -authMode apiKey`, the argument domain).
  Probe engine CLIs with `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN
  -u ANTHROPIC_BASE_URL`, or the harness's own variables redirect `claude`.

## Interface

The UI follows Apple's Human Interface Guidelines; read the relevant HIG page
before changing a surface. Deviation from the global rules: menu items and button
titles use title-style capitalization, as HIG Menus and Buttons require; labels,
section headers, and body text stay in sentence case. A second one: system-drawn
secondary text measures under 4.5:1 in the light appearance (settings footers
3.95:1, System Settings itself 3.90:1; menu section headers and disabled rows
lower), measured live on 2026-09-23. These are the system's own styles and pass
with Increase Contrast, so never override them with custom colors.

## Rules and conventions

Topic-specific rules live in `.claude/rules/*.md` and are auto-loaded when
matching files are touched.

| File | Covers |
|------|--------|
| `architecture.md` | Status item and its menu, settings panes, global hotkey, paste-landed editability detection, providers, and update checking |
