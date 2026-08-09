# Build and release

Relocated from the repo root `CLAUDE.md`. User-facing install and release
instructions also live in [`README.md`](../README.md); this file carries the
detail an engineer needs.

## Local build

- **Build and assemble the app bundle:** `./build.sh`. It runs `swift build -c
  release`, copies the binary and `Resources/` into `Translate Like Me.app`, and
  code-signs it.
- **CRITICAL:** `swift build` alone updates only `.build/release/`; it does NOT
  refresh the binary inside `Translate Like Me.app`. Always run `./build.sh`
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

Local `./build.sh` bundles keep whatever version is committed in `Info.plist`;
they are for local use, not distribution. CI signs ad-hoc (the stable identity
is absent on the runner), which is expected.
