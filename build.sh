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

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$BIN" "$APP/Contents/MacOS/$BIN"
# Fail loudly, before anything is signed, if the linked-on SDK ever drops back
# to the deployment target.
SDK_STAMP="$(vtool -show-build "$APP/Contents/MacOS/$BIN" | awk '/ sdk /{print $2}')"
if [[ "$SDK_STAMP" != "$(xcrun --show-sdk-version)" ]]; then
    echo "error: binary is stamped sdk $SDK_STAMP, expected $(xcrun --show-sdk-version)" >&2
    exit 1
fi
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
# Stamp the latest release tag, as CI stamps the tag it builds, so a local build
# never reports an older version than the release (which would raise the update
# alert on every launch). --abbrev=0: the tag itself, not "2.0-5-gabc".
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [[ -n "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
# The Icon Composer icon: Assets.car for macOS 26+ (system glass, dark and tinted
# appearances) plus a flat AppIcon.icns for macOS 15. Needs Xcode 26+ (actool).
# Regenerate its foreground layer with scripts/make-icon-layers.py.
xcrun actool "Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -t tlm-icon)" >/dev/null
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
    codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" "$APP"
elif [[ "${RELEASE:-}" == 1 ]]; then
    echo "error: RELEASE=1 but no Developer ID Application identity for team $TEAM_ID" >&2
    exit 1
else
    echo "warning: no Developer ID Application identity, signing ad hoc (Accessibility will re-prompt)"
    codesign --force --sign - "$APP"
fi

echo "Done: $PWD/$APP"
echo "Launch with: open \"$PWD/$APP\""
