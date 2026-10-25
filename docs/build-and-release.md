# Build and release

Relocated from the repo root `CLAUDE.md`. Installation and the product overview
live in the [README](../README.md), with setup, usage, and troubleshooting in
the [user guide](user-guide.md). This file carries the engineering procedures.

## Local build

The app manifest uses SwiftPM tools 6.2 and Swift 6 language mode, with macOS 15
support. MLX Swift 0.32.3 requires a Swift 6.3 compiler (Xcode 26.6 or later).
The explicit swift-collections 1.6.0 constraint keeps tokenizer dependencies
compatible with CI's Swift 6.3.3; 1.7 requires Swift 6.4.
`build.sh` includes the WhisperKit, Whisper and Silero license notices. Parakeet
and its FluidAudio dependency are no longer included in the app.
Qwen runs through MLX Audio Swift and MLX Swift. CMake builds the pinned MLX
Metal kernels (`scripts/build-mlx-metallib.sh`), using the app's macOS minimum;
`build.sh` embeds them before signing. Kernel build output is keyed by source
revision, SDK and deployment target. The build also copies materialized resource
bundles from the current SwiftPM graph and packages resolved upstream notices.
Unused graph targets need not produce bundles; stale bundles outside the graph
must stay out of the app. CMake is required locally and installed in CI.

Cloning `.build` into another worktree preserves absolute paths in Swift's
release `ModuleCache` and the `.build/mlx-metal/` CMake cache. Recreate those
generated caches in the destination before building; keep the source
checkout's caches intact.

- **Build and assemble the app bundle:** `./build.sh`. It builds an arm64-only
  release binary, copies it and `Resources/` into `Translate Like Me Dev.app`
  (`Translate Like Me.app` with `RELEASE=1`),
  compiles the Icon Composer icon, and code-signs the bundle.
- **Localization:** the app target compiles with `-emit-localized-strings`
  (`Package.swift`), so the compiler lists every localizable string;
  `build.sh` runs `scripts/sync-strings.py`, which syncs them into
  `Resources/Localizable.xcstrings` and stops the build on any string not
  translated into every language, and `xcstringstool compile` writes one
  `<language>.lproj` per localization, English included (CLAUDE.md,
  Localization).
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
  layers (brows, eyes, pupils, open mouth) are flat SVGs, so macOS 27 gives
  each its own Liquid Glass, and `icon.json` holds their colors and dark and
  tinted variants; both are written by `uv run scripts/make-icon-layers.py`.
  It then renders `Resources/appicon_1024.png` from the icon with `ictool`
  (inside Icon Composer.app, which also renders every appearance for review).
  The face smiles because the earlier one, frowning and swearing "@!%$", read
  as angry to users (replaced 2026-10-23).
- **Menu bar icon:** `Resources/MenuBarIcon.png` (idle, the smiling face as an outline)
  and `MenuBarBusy.png` (a solid tile with the features cut out) are template
  images drawn by `uv run scripts/make-menubar-icons.py`, in the outline / fill
  pairing Rota and Watch Me While I Fall Asleep use.
- **Screenshots:** `./capture-screenshots.sh` rebuilds the app and regenerates
  `screenshots/` (the menu, General, Translation, Rewrite, and the listening and
  recognizing dictation indicators, translation and Rewrite progress, and the
  Dictation settings pane), each in the light appearance
  and in Dark Mode (`*-dark.png`, which Victor's personal website shows to dark-mode visitors).
  It switches the system appearance for the dark pass and restores the
  user's on exit. ScreenCaptureKit composites only the app and an opaque
  backdrop, excluding alerts, the Dock and unrelated windows. The script waits
  for Settings activation to settle and verifies the target's exact frame before
  and after capture; a closed or resized target fails. Its header comment explains
  the settings overrides and restoration. The terminal and the build need
  Accessibility, so a build under a new signature prompts until granted.
  `CAPTURE_ONBOARDING_ONLY=1 CAPTURE_OUT=<dir> ./capture-screenshots.sh`
  traverses translation setup and the dictation-only route, including Back and
  Done, with synthetic engine health and no microphone access. Add
  `CAPTURE_APPEARANCE=current` to leave the system theme and pointer untouched;
  the capture fails if the theme changes while a frame is being recorded.
  `CAPTURE_ACTIVITY_ONLY=1 CAPTURE_OUT=<dir> ./capture-screenshots.sh` captures
  all four activity states, waits for each panel frame to settle, and presses
  each Cancel button to verify dismissal.
  Add `CAPTURE_LANGUAGE=de` to check the German labels.
  Release 3.7.12 captures use `CAPTURE_LOCAL_MODEL=gemma-4-12b` to show the
  newly available model in Translation and Manage Models.
  `CAPTURE_RESULTS_ONLY=1 CAPTURE_OUT=<dir> ./capture-screenshots.sh` checks
  the recovery submenu's empty, partial and full states.
- **CRITICAL:** `swift build` alone updates only the SwiftPM build directory; it
  does NOT refresh the binary inside the assembled `.app`. Always run `./build.sh`
  before installing or testing the bundle, otherwise you run a stale binary.
- **Install for local use:** copy `Translate Like Me Dev.app` to `/Applications`
  and launch it alongside the release. It has its own settings and permission
  grants. Quit only a development copy you intend to replace; keep the installed
  release available. Both are menu-bar accessories (no Dock icon).
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
  `Translate-Like-Me-vX.Y.Z-macOS.zip`. It reads the team-wide notarytool profile
  `notary-K2GT9Q4S6U` from the login keychain (`xcrun notarytool
  store-credentials`, command in the script header); other apps of the same
  team reuse it. `build.sh` passes `Resources/Entitlements.plist` to the final
  signature so dictation can use microphone input under the hardened runtime.

## Release process

Automated via GitHub Actions ([`.github/workflows/build.yml`](../.github/workflows/build.yml)):

1. Complete the local pre-commit gate, push the candidate commit to main and
   wait for the entire main CI run to succeed on that exact commit. Fix a failed
   candidate and repeat this step under the same planned version. Follow the
   global sequential-release rule; preparation failures never consume versions.
2. Only then run `git tag -a vX.Y.Z -F notes.md` and `git push origin vX.Y.Z`.
   Never push the candidate commit and its final release tag together. The annotation's
   first line is the title ("Translate Like Me X.Y.Z"); its body, after a blank
   line, is the release notes in Markdown. The workflow refuses a tag that is
   not `vX.Y.Z` or not above every earlier tag: Sparkle offers only a higher
   version, so a lower number never reaches anybody on the newer release.
3. The workflow runs SwiftLint and tests, imports the Developer ID
   identity and the notarytool profile into a temporary keychain, builds and
   signs via `RELEASE=1 build.sh` (which stamps `X.Y.Z` from the tag), notarizes
   and staples via `notarize.sh`, and publishes
   a GitHub Release with `Translate-Like-Me-vX.Y.Z-macOS.zip` attached. The keychain
   is deleted at the end.
4. It also generates `appcast.xml` with Sparkle's `generate_appcast`: this
   release only, its EdDSA signature, and the tag body embedded as Markdown
   release notes (also the GitHub release body). The app's `SUFeedURL` is
   `releases/latest/download/appcast.xml`, so publishing the release is what
   offers it to installed copies.
5. A second job, `homebrew`, points the cask in
   [wiltodelta/homebrew-tap](https://github.com/wiltodelta/homebrew-tap)
   (`Casks/translate-like-me.rb`) at the new release, committing the new
   `version` and the zip's `sha256` (the build job's `zip-sha256` output). It
   pushes with the `HOMEBREW_TAP_DEPLOY_KEY` secret, the private half of the
   write deploy key "translate-like-me release" on the tap (created 2026-09-26;
   no expiry, no other copy: to rotate, make a new pair, replace the deploy key
   and the secret), and fails loudly without it. The cask has `auto_updates
   true`, so brew leaves installed copies to Sparkle; the bump only keeps new
   installs current.

Sparkle (`Updater.swift`, `SPUStandardUpdaterController`) is the one updater.
`build.sh` copies `Sparkle.framework` from the SwiftPM build into
`Contents/Frameworks`, adds the `@executable_path/../Frameworks` rpath, removes
its XPC services (they exist for sandboxed apps; this one is not), ships its
MIT license as `Sparkle LICENSE.txt`, and signs `Autoupdate`, `Updater.app`,
the framework and the app in that order, per Sparkle's manual-signing docs.
The final app signature uses `Resources/Entitlements.plist` to allow microphone
input under the hardened runtime; `Info.plist` contains the microphone purpose.
WhisperKit is statically linked through SwiftPM. Its MIT notice and Whisper's
MIT notice and Silero's MIT notice are copied into Resources. Dictation model,
speech detector and tokenizer assets download
during setup, on first enable or from Manage Models into the bundle-id-specific
Application Support directory; they
are not bundled with the app or shared with the installed release's dev cache. The
EdDSA private key is in the login keychain (Sparkle's `generate_keys`), in the
1Password item as "Sparkle EdDSA private key" and in the `SPARKLE_PRIVATE_KEY`
secret; one key serves every app of the team, and `SUPublicEDKey` in
`Info.plist` is its public half. Losing it means shipping a new public key in a
release signed with the old one. The end-to-end path (old build, local appcast,
Install Update, relaunch into the new version) was run on 2026-09-24.

The repository secrets it reads are `DEVELOPER_ID_P12_BASE64` and
`DEVELOPER_ID_P12_PASSWORD` (the identity as a `.p12`),
`NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`,
`SPARKLE_PRIVATE_KEY`, and `HOMEBREW_TAP_DEPLOY_KEY` for the cask bump. Only tag
builds read them, and GitHub never passes them to pull requests from forks; branch
builds stay ad hoc. The Developer ID certificate expires on 2031-09-17: renew it
on the Apple Developer portal and reset the two identity secrets.

`build.sh` stamps the bundle with the latest tag (`git describe --tags
--abbrev=0`); without a tag a local build keeps the `0.0.0` placeholder from the
committed `Info.plist` and CI refuses to build. A local build never reports
an older version than the release, which Sparkle would then offer over it.
Local bundles are for local use, not distribution.

Verify a release before moving on (re-download, then check the signature and the
stapled ticket):

```bash
gh release download vX.Y.Z -p "*.zip" -D /tmp/asset-check && \
  ditto -x -k /tmp/asset-check/*.zip /tmp/asset-check/app && \
  spctl -a -vv "/tmp/asset-check/app/Translate Like Me.app" && \
  xcrun stapler validate "/tmp/asset-check/app/Translate Like Me.app"
```

## Website

The product page is <https://wiltodelta.com/projects/translate-like-me/> on
Victor's personal website. `website-content.json` supplies its introduction and
feature sections from the published release tag, alongside the General settings
screenshots. The site's icon is generated separately from
`assets/brand-sources/translate-like-me.png` by `pnpm run assets:build`;
refreshing release content alone does not replace it. For every release, follow
`wiltodelta-app/docs/product-updates.md`, "What product repositories owe the site",
for website impact assessment, asset and copy preparation, preview, the required
publication decision and live verification.

Since 2026-10-23 `translatelikeme.com` only
redirects there: a Cloudflare Redirect Rule ("Redirect to wiltodelta.com
product page") answers every request on the root and `www` with a 301, over
a proxied placeholder A record `192.0.2.1` and a proxied `www` CNAME to the
root. The domain is registered at Namecheap (2026-10-01) with Cloudflare DNS
on the free plan. Keep two TXT records, since deleting either unverifies the
domain:

- `_github-pages-challenge-wiltodelta`: stops any other account publishing
  GitHub Pages on the domain.
- `google-site-verification=...` on the root: keeps the Google Search Console
  property (added 2026-10-01) for the change of address.

Mail to any address at the domain goes to kuznetsov.va@gmail.com through
Cloudflare Email Routing (catch-all rule; the MX, SPF and DKIM records are
Cloudflare's). Cloudflare is there for that: Email Routing is free only with
Cloudflare DNS, and the free tiers elsewhere refuse a newly registered domain
(Forward Email) or hold one domain (ImprovMX, already used).
