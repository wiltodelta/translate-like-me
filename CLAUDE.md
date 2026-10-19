# Translate Like Me

You are a **principal Swift/macOS engineer** maintaining a menu-bar app that
translates the current selection via global hotkeys, one per language pair (up
to three), auto-detecting the direction and applying the user's writing style,
and rewrites selected rough notes into a finished message in the same language
with named Rewrite presets (up to three), plus local multilingual dictation.
SwiftUI + AppKit, SwiftPM; Sparkle for updates and WhisperKit for local ASR. Supports the
three latest macOS releases (15+) on Apple silicon only.

Shared rules for our macOS apps: `~/Documents/GitHub/claude-config/docs/macos-apps.md`; this file states only what differs.

## Build and release

Assemble the bundle with `./build.sh` (needs Xcode 26+: `actool` compiles the
Icon Composer icon); `swift build` alone leaves a stale binary inside
`Translate Like Me.app`. Releases are driven by `vX.Y.Z` git tags through GitHub
Actions, which signs with the Developer ID from repository secrets and
notarizes (`notarize.sh`), then bumps the cask in `wiltodelta/homebrew-tap`;
locally `build.sh` signs with the same identity from the keychain. The
website `translatelikeme.com` is `site/index.html` on GitHub Pages, its DNS
and mail forwarding in Cloudflare. Full
detail, including the secrets and where the keys are kept (1Password):
`docs/build-and-release.md`.

## Code quality

- `bash maintain.sh` runs the canonical Swift gate.
- CI can lag local Swift. In subprocess tests, use explicit `@Sendable` task
  closures, a precomputed deadline and the concrete test type: the dynamic `Self`
  form failed Swift 6.3.3's region-based isolation checker.
- Lint config in `.swiftlint.yml` scans `Sources/` and `Tests/` at 120-column lines (fixtures inside multiline strings exempt, `Tests/.swiftlint.yml`).
- `Tests/TranslateLikeMeTests/` covers pure logic, selection orchestration with
  injected effects, and `ProcessRunner` with synthetic subprocesses. UI,
  Accessibility, CGEvent and Sparkle require native verification; render UI changes with
  `./capture-screenshots.sh` (it also regenerates `screenshots/`, light and
  dark, flipping the system to Dark Mode and back; needs
  Accessibility and Screen Recording for the terminal and a Mac left alone).
  ScreenCaptureKit composites only the app and an opaque backdrop, excluding
  unrelated windows, alerts and the Dock. A closed or resized target fails the
  capture; Settings activation settles before the frame and backdrop are measured.
  Inspect every generated image. System Events `entire contents`
  does not reach the SwiftUI controls in Settings: press them by walking
  `AXUIElement` children and matching the title or accessibility label. A
  picker is an `AXPopUpButton` (its value is the selection): press it, then
  press the `AXMenuItem` by title, and read the result back from the
  defaults (`plutil -extract languagePairs raw`, base64 JSON) rather than
  sending keys, which land in whatever app is in front.
- A build without `RELEASE=1` is `com.wiltodelta.translatelikeme.dev`: its own
  settings domain, login item and Accessibility grant (granted once), so it
  runs beside the installed app; if both have the same shortcuts set, quit one
  before testing them. Override a setting for one launch with the argument
  domain (`open -n "Translate Like Me.app" --args -provider grok`). Onboarding
  opens with `-didCompleteFirstRun NO -languagePairs '<5b5d>'` (no pairs). The
  bundle is hardened, so lldb cannot attach: read a crash's stack from
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
before changing a surface. Secondary text the app draws uses
`Color.secondaryText` (primary at 0.66 opacity), never `.secondary`, which the
SwiftLint rule `no_system_secondary_text` refuses: the system style measured
3.88-3.93:1 on the settings forms (2026-10-11), under 4.5:1.
The result popup uses an opaque semantic backing because glass could not keep
text above 4.5:1 across desktop colors and tint settings (2026-10-17). watch-me-sleep and rota use the same token.
Deviation from the global rules: the status menu's section headers and disabled
rows stay as NSMenu draws them (about 1.9:1 in light), since the app does not
draw them.

## Rules and conventions

Topic-specific rules live in `.claude/rules/*.md` and are auto-loaded when
matching files are touched.

| File | Covers |
|------|--------|
| `dictation.md` | Minimal local dictation, model installation, recording, cancellation, and caret delivery |
| `architecture.md` | Status item and its menu, settings panes, onboarding and its engine checks, global hotkey, language pairs and Rewrite presets, selection validation and clipboard ownership, providers, and update checking |
