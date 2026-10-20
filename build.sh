#!/bin/bash
# Build TranslateLikeMe and assemble a macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP="Translate Like Me.app"
BIN="TranslateLikeMe"

# Apple silicon only: macOS 27 dropped Intel, and the app supports the three
# latest macOS releases (15+).
#
# The native build system is used on purpose: SwiftPM's default swiftbuild (Xcode
# 27, measured 2026-09-23) stamps the binary's LC_BUILD_VERSION sdk with the
# deployment target (15.0) instead of the SDK it compiled against (27.0), and
# AppKit reads that stamp to decide which SDK the app was linked on - an old stamp
# risks the pre-Liquid Glass compatibility look on macOS 26+.
BUILD=(swift build -c release --arch arm64 --build-system native)
echo "Building (release, arm64)..."
"${BUILD[@]}" 2> >(grep -v "build-system native' has been deprecated" >&2)
BIN_DIR="$("${BUILD[@]}" --show-bin-path 2>/dev/null)"
# Merges the strings the compiler listed (Package.swift) into the String
# Catalog, as Xcode does on each build, and fails, before anything is
# assembled, on a string missing a translation.
python3 -I scripts/sync-strings.py .build/localized-strings

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$BIN" "$APP/Contents/MacOS/$BIN"
# Sparkle, found through @rpath: SwiftPM links it with @loader_path only, which
# is the build directory, so the bundle's Frameworks folder is added. Its XPC
# services exist for sandboxed apps; this app is not sandboxed, so Sparkle's
# docs allow removing them (and there is less to sign).
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$BIN"
# Sparkle is MIT licensed, which asks for its notice to ship with it.
cp ".build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle LICENSE.txt"
# Local speech runtime and models retain their upstream MIT notices.
cp .build/checkouts/argmax-oss-swift/LICENSE "$APP/Contents/Resources/WhisperKit LICENSE.txt"
cp .build/checkouts/argmax-oss-swift/NOTICES "$APP/Contents/Resources/WhisperKit NOTICES.txt"
cp Resources/Whisper-LICENSE.txt "$APP/Contents/Resources/Whisper LICENSE.txt"
cp Resources/Silero-LICENSE.txt "$APP/Contents/Resources/Silero LICENSE.txt"
# Fail loudly, before anything is signed, if the linked-on SDK ever drops back
# to the deployment target.
SDK_STAMP="$(vtool -show-build "$APP/Contents/MacOS/$BIN" | awk '/ sdk /{print $2}')"
if [[ "$SDK_STAMP" != "$(xcrun --show-sdk-version)" ]]; then
    echo "error: binary is stamped sdk $SDK_STAMP, expected $(xcrun --show-sdk-version)" >&2
    exit 1
fi
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
# Only a release build is com.wiltodelta.translatelikeme. Every other build is
# com.wiltodelta.translatelikeme.dev, a separate app with its own settings, login
# item and Accessibility grant, so building and checking never touch the copy
# someone relies on. It does not check for updates.
if [[ "${RELEASE:-}" != 1 ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wiltodelta.translatelikeme.dev" \
        -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist"
fi
# Stamp the latest release tag, as CI stamps the tag it builds, so a local build
# never reports an older version than the release (which would make Sparkle
# offer the release over it). --abbrev=0: the tag itself, not "2.0-5-gabc".
# CI must have the tag; a local checkout without one keeps the 0.0.0 placeholder.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [[ -n "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "error: no git tag to take the version from" >&2
    exit 1
fi
# The oldest supported macOS lives in Info.plist; Package.swift must say the same.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
grep -q ".macOS(\"$MIN_MACOS\")" Package.swift ||
    { echo "error: Package.swift platform differs from LSMinimumSystemVersion $MIN_MACOS" >&2; exit 1; }
# The Icon Composer icon: Assets.car for macOS 26+ (system glass, dark and tinted
# appearances) plus a flat AppIcon.icns for older releases. Needs Xcode 26+
# (actool). Regenerate its layers and icon.json with scripts/make-icon-layers.py.
# Absolute paths: actool resolves relative ones against the working directory of
# its long-lived agent, which is wherever it first started, not this script's.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -t tlm-icon)" >/dev/null
# One <language>.lproj per localization, English included: without en.lproj an
# English-first Mac would resolve to its second preferred language.
for CATALOG in Localizable InfoPlist; do
    xcrun xcstringstool compile "Resources/$CATALOG.xcstrings" --output-directory "$APP/Contents/Resources" >/dev/null
done
cp "Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "Resources/MenuBarBusy.png" "$APP/Contents/Resources/MenuBarBusy.png"

# Sign with the team's Developer ID Application identity when the keychain has it:
# its stable designated requirement keeps the Accessibility (TCC) grant across
# rebuilds and releases, and with the hardened runtime and (RELEASE=1) a secure
# timestamp it is what notarization requires (notarize.sh). The timestamp needs
# Apple's server, so everyday builds skip it and still work offline. Without the
# identity (contributors, CI branch builds) the bundle is signed ad hoc, which
# runs but re-prompts for Accessibility after every rebuild.
TEAM_ID="K2GT9Q4S6U"
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v team="($TEAM_ID)" '/Developer ID Application:/ && index($2, team) {print $2; exit}')"
if [[ -n "$SIGN_IDENTITY" ]]; then
    TIMESTAMP="--timestamp=none"
    [[ "${RELEASE:-}" == 1 ]] && TIMESTAMP="--timestamp"
    SIGN=(codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY")
elif [[ "${RELEASE:-}" == 1 ]]; then
    echo "error: RELEASE=1 but no Developer ID Application identity for team $TEAM_ID" >&2
    exit 1
else
    echo "warning: no Developer ID Application identity, signing ad hoc (Accessibility will re-prompt)"
    SIGN=(codesign --force --sign -)
fi
# Inside out, in the order Sparkle's docs give: its helpers, the framework, then
# the app (no --deep, which would re-sign the helpers without their options).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" --entitlements Resources/Entitlements.plist "$APP"

echo "Done: $PWD/$APP"
echo "Launch with: open \"$PWD/$APP\""
