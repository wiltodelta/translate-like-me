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
  `screenshots/` (menu, General, Translation) in the current system
  appearance; its header comment explains the backdrop capture, the settings
  overrides and the covered-window check. The terminal and the build need
  Accessibility, so a build under a new signature prompts until granted.
- **CRITICAL:** `swift build` alone updates only the SwiftPM build directory; it
  does NOT refresh the binary inside `Translate Like Me.app`. Always run `./build.sh`
  before installing or testing the bundle, otherwise you run a stale binary.
- **Install for local use:** quit the running app, replace
  `/Applications/Translate Like Me.app`, relaunch. It is a menu-bar accessory
  (no Dock icon).
- **Signing:** `build.sh` signs with the "Developer ID Application: Victor
  Kuznetsov (K2GT9Q4S6U)" identity when the keychain has it, with the hardened
  runtime and a secure timestamp; its designated requirement keeps the
  Accessibility grant across rebuilds and releases. Without it the bundle is
  signed ad hoc and Accessibility re-prompts after every rebuild. The identity (with
  its private key) and the App Store Connect API key (team key "Notarization",
  role Developer, used only for notarization) are in the login keychain and
  backed up in 1Password, Private vault, item "Apple Developer ID: Victor
  Kuznetsov (K2GT9Q4S6U)": the `.p12` with its password, the `.p8`, the key
  and issuer IDs, and the commands that restore both on a new Mac.
- **Notarization:** `RELEASE=1 ./build.sh && ./notarize.sh` signs with a secure
  timestamp (everyday builds skip it, so they work offline), submits the bundle,
  staples the ticket, checks it with `spctl` and writes
  `Translate-Like-Me-vX.Y-macOS.zip`. It reads the team-wide notarytool profile
  `notary-K2GT9Q4S6U` from the login keychain (`xcrun notarytool
  store-credentials`, command in the script header); other apps of the same
  team reuse it. An app that needs a hardened-runtime entitlement (the camera,
  for example) must pass `--entitlements` to `codesign`; this one needs none.

## Release process

Automated via GitHub Actions ([`.github/workflows/build.yml`](../.github/workflows/build.yml)):

1. `git tag -a vX.Y -F notes.md` then `git push origin vX.Y`. The annotation's
   first line is the title ("Translate Like Me X.Y"); its body, after a blank
   line, is the release notes in Markdown.
2. The workflow runs SwiftLint and tests, imports the Developer ID
   identity and the notarytool profile into a temporary keychain, builds and
   signs via `RELEASE=1 build.sh` (which stamps `X.Y` from the tag), notarizes
   and staples via `notarize.sh`, and publishes
   a GitHub Release with `Translate-Like-Me-vX.Y-macOS.zip` attached. The keychain
   is deleted at the end.
3. It also generates `appcast.xml` with Sparkle's `generate_appcast`: this
   release only, its EdDSA signature, and the tag body embedded as Markdown
   release notes (also the GitHub release body). The app's `SUFeedURL` is
   `releases/latest/download/appcast.xml`, so publishing the release is what
   offers it to installed copies.

Sparkle (`Updater.swift`, `SPUStandardUpdaterController`) is the one updater.
`build.sh` copies `Sparkle.framework` from the SwiftPM build into
`Contents/Frameworks`, adds the `@executable_path/../Frameworks` rpath, removes
its XPC services (they exist for sandboxed apps; this one is not), ships its
MIT license as `Sparkle LICENSE.txt`, and signs `Autoupdate`, `Updater.app`,
the framework and the app in that order, per Sparkle's manual-signing docs. The
EdDSA private key is in the login keychain (Sparkle's `generate_keys`), in the
1Password item as "Sparkle EdDSA private key" and in the `SPARKLE_PRIVATE_KEY`
secret; one key serves every app of the team, and `SUPublicEDKey` in
`Info.plist` is its public half. Losing it means shipping a new public key in a
release signed with the old one. The end-to-end path (old build, local appcast,
Install Update, relaunch into the new version) was run on 2026-09-24.

The repository secrets it reads are `DEVELOPER_ID_P12_BASE64` and
`DEVELOPER_ID_P12_PASSWORD` (the identity as a `.p12`),
`NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, and
`SPARKLE_PRIVATE_KEY`. Only tag builds
read them, and GitHub never passes them to pull requests from forks; branch
builds stay ad hoc. The Developer ID certificate expires on 2031-09-17: renew it
on the Apple Developer portal and reset the two identity secrets.

`build.sh` stamps the bundle with the latest tag (`git describe --tags
--abbrev=0`), falling back to the committed `Info.plist` without tags, so a
local build never reports an older version than the release, which Sparkle
would then offer over it. Local bundles are for local use, not
distribution.

Verify a release before moving on (re-download, then check the signature and the
stapled ticket):

```bash
gh release download vX.Y -p "*.zip" -D /tmp/asset-check && \
  ditto -x -k /tmp/asset-check/*.zip /tmp/asset-check/app && \
  spctl -a -vv "/tmp/asset-check/app/Translate Like Me.app" && \
  xcrun stapler validate "/tmp/asset-check/app/Translate Like Me.app"
```
