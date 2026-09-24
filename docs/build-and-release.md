# Build and release

Relocated from the repo root `CLAUDE.md`. User-facing install and release
instructions also live in [`README.md`](../README.md); this file carries the
detail an engineer needs.

## Local build

- **Build and assemble the app bundle:** `./build.sh`. It builds an arm64-only
  release binary, copies it and `Resources/` into `Translate Like Me.app`,
  compiles the Icon Composer icon, and code-signs the bundle.
- **Native build system, on purpose:** SwiftPM's default swiftbuild (Xcode 27,
  measured 2026-09-23) stamps the binary's `LC_BUILD_VERSION` sdk with the
  deployment target (15.0) instead of the SDK it compiled against, and AppKit
  reads that stamp to pick the linked-on behavior. `build.sh` passes
  `--build-system native` and fails if the stamp differs from
  `xcrun --show-sdk-version`.
- **App icon:** `Resources/AppIcon.icon` is the Icon Composer source (square
  layers; macOS 26+ masks the icon and would otherwise put the old round art in
  a gray plate). `build.sh` compiles it with `xcrun actool` into `Assets.car`
  plus a flat `AppIcon.icns` for macOS 15; this needs Xcode 26 or later on a
  macOS 26 host (on macOS 15 actool's asset agent crashes, so CI runs on
  `macos-26`). Its
  foreground layer is generated from `Resources/appicon_1024.png` by
  `uv run scripts/make-icon-layers.py`.
- **Screenshots:** `./capture-screenshots.sh` rebuilds the app and regenerates
  `screenshots/` in the current system appearance; its header comment explains
  the backdrop capture, the settings overrides and the covered-window check.
- **CRITICAL:** `swift build` alone updates only the SwiftPM build directory; it
  does NOT refresh the binary inside `Translate Like Me.app`. Always run `./build.sh`
  before installing or testing the bundle, otherwise you run a stale binary.
- **Install for local use:** quit the running app, replace
  `/Applications/Translate Like Me.app`, relaunch. It is a menu-bar accessory
  (no Dock icon).
- The stable signing identity here is "Translate Like Me Dev" (see the comment in
  `build.sh`); the TCC grant it preserves is Accessibility.
- The build is self-signed for personal use, not notarized. Gatekeeper warns on
  other machines; fine for personal installs.

## Release process

Automated via GitHub Actions ([`.github/workflows/build.yml`](../.github/workflows/build.yml)):

1. `git tag -a vX.Y -m "Translate Like Me X.Y"` then `git push origin vX.Y`.
2. The workflow stamps `X.Y` into `Info.plist` (`CFBundleShortVersionString` and
   `CFBundleVersion`), runs SwiftLint and tests, builds via `build.sh`, zips as
   `TranslateLikeMe-vX.Y-macOS.zip`, and publishes a GitHub Release with it
   attached. `UpdateChecker` compares that tag to the installed version.

`build.sh` stamps the bundle with the latest tag (`git describe --tags
--abbrev=0`), falling back to the committed `Info.plist` without tags, so a
local build never reports an older version than the release and raises the
update alert on every launch. Local bundles are for local use, not
distribution. CI signs ad-hoc (the stable identity
is absent on the runner), which is expected.

## Re-sign the release asset locally (every release)

CI-built release zips are ad-hoc signed (see above), but the Accessibility
grant is keyed to the stable "Translate Like Me Dev" identity. Installing a
CI-built zip therefore loses Accessibility and re-prompts. After every tagged
release, replace the asset with a locally signed build of the same tag:

```bash
git checkout vX.Y                 # exactly the released commit
./build.sh                         # stamps X.Y from the tag; signs with the stable identity
zip -r -y TranslateLikeMe-vX.Y-macOS.zip "Translate Like Me.app"
gh release upload vX.Y TranslateLikeMe-vX.Y-macOS.zip --clobber
git switch main
```

Verify before moving on (re-download, then check the identity is NOT ad-hoc):

```bash
gh release download vX.Y -p "*.zip" -D /tmp/asset-check && \
  ditto -x -k /tmp/asset-check/*.zip /tmp/asset-check/app && \
  codesign -dvv "/tmp/asset-check/app/Translate Like Me.app" 2>&1 | grep Authority
```

The long-term fix is Developer ID signing + notarization in CI (secrets-based
identity import), which removes this manual step entirely; until then this
re-sign is part of releasing.
