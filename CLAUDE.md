# Translate Like Me

You are a **principal Swift/macOS engineer** maintaining a menu-bar app that
translates the current selection via global hotkeys, one per language pair (up
to three), auto-detecting the direction and applying the user's writing style,
and rewrites selected rough notes into a finished message in the same language
with named Rewrite presets (up to three).
SwiftUI + AppKit, SwiftPM; the one dependency is Sparkle (updates). Supports the
three latest macOS releases (15+) on Apple silicon only.

## Build and release

Assemble the bundle with `./build.sh` (needs Xcode 26+: `actool` compiles the
Icon Composer icon); `swift build` alone leaves a stale binary inside
`Translate Like Me.app`. Releases are driven by `vX.Y` git tags through GitHub
Actions, which signs with the Developer ID from repository secrets and
notarizes (`notarize.sh`), then bumps the cask in `wiltodelta/homebrew-tap`;
locally `build.sh` signs with the same identity from the keychain. The
website `translatelikeme.com` is `site/index.html` on GitHub Pages, its DNS
and mail forwarding in Cloudflare. Full
detail, including the secrets and where the keys are kept (1Password):
`docs/build-and-release.md`.

## Code quality

- `bash maintain.sh` runs the canonical Swift gate.
- Lint config in `.swiftlint.yml` scans `Sources/` at 120-column lines.
- Tests cover the pure logic (`Shortcut` formatting and menu key equivalents,
  `Languages` pair editing, the full macOS language list and the
  suggestion chain for new pairs (unchosen when it runs out), no pairs for a
  new user, `EngineHealth` mapping of onboarding checks, migration
  from the single pair and of the global style into the pairs, the pair
  prompt, `Rewrite` presets and their prompt, `HarnessDefaults` config reading,
  `HarnessModels` catalog parsing (claude, codex, grok) and `HarnessChoice`, the
  settings model/effort pick,
  `LimitDetector` and `JSONErrorMessage` engine payload parsing, and removal
  of the keys the dropped API-key mode stored). UI, Accessibility, CGEvent,
  Sparkle and CLI-subprocess code is not unit-tested; render UI changes with
  `./capture-screenshots.sh` (it also regenerates `screenshots/`, light and
  dark, flipping the system to Dark Mode and back; needs
  Accessibility and Screen Recording for the terminal and a Mac left alone;
  a closed menu mid-run, or a system overlay over the capture (an AirPods
  notice, a stuck transparent `screencaptureui` window: `kill -TERM` it when
  nothing is recording), fails it, rerun once; the General pane's bottom margin
  reaches the Dock, and a Dock label there passes the covered-window check, so
  look at the bottom of `general*.png` before committing). System Events `entire contents`
  does not reach the SwiftUI controls in Settings: press them by walking
  `AXUIElement` children and matching the title or accessibility label. A
  picker is an `AXPopUpButton` (its value is the selection): press it, then
  press the `AXMenuItem` by title, and read the result back from the
  defaults (`plutil -extract languagePairs raw`, base64 JSON) rather than
  sending keys, which land in whatever app is in front.
- Live runs of a dev build read and write the installed app's settings domain
  (`com.wiltodelta.translatelikeme`): save and restore any key a test changes,
  or override it for one launch without writing (`open -n "Translate Like
  Me.app" --args -provider grok`, the argument domain). A dev launch also
  runs the launch migrations on the real settings, so `defaults export
  com.wiltodelta.translatelikeme <file>` before the first one. Onboarding opens
  with `-didCompleteFirstRun NO -languagePairs '<5b5d>'` (no pairs), but adding
  a pair or picking an engine there still writes the real domain. The bundle
  is hardened, so lldb cannot attach: read a crash's stack from
  `~/Library/Logs/DiagnosticReports/TranslateLikeMe-*.ips` (JSON after the
  first line).
  Probe engine CLIs with `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN
  -u ANTHROPIC_BASE_URL`, or the harness's own variables redirect `claude`.
  Check a prompt change live with a temporary XCTest that calls
  `Translator.translate` or `Translator.rewrite` behind an env-var guard
  (`swift test --filter`, three runs per case, delete it after), rather than
  by pressing hotkeys: keystrokes land in whatever window is in front.

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
| `architecture.md` | Status item and its menu, settings panes, onboarding and its engine checks, global hotkey, language pairs and Rewrite presets, paste-landed editability detection, providers, and update checking |
