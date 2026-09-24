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

# Sign with a stable self-signed identity so the Accessibility (TCC) grant
# persists across rebuilds. The identity lives in the login keychain; recreate it
# with (one-time):
#   openssl req -x509 -newkey rsa:2048 -keyout k.key -out c.crt -days 3650 -nodes \
#     -subj "/CN=$SIGN_IDENTITY" -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -out c.p12 -inkey k.key -in c.crt -passout pass:tlm \
#     -name "$SIGN_IDENTITY" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
#   security import c.p12 -k ~/Library/Keychains/login.keychain-db -P tlm -A
# Falls back to ad-hoc if the identity is missing (then Accessibility re-prompts).
SIGN_IDENTITY="Translate Like Me Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || true
else
    echo "warning: '$SIGN_IDENTITY' not found, falling back to ad-hoc (Accessibility will re-prompt)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Done: $PWD/$APP"
echo "Launch with: open \"$PWD/$APP\""
