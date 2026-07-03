#!/bin/bash
# Build TranslateLikeMe and assemble a macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP="Translate Like Me.app"
BIN="TranslateLikeMe"

echo "Building (release)..."
swift build -c release

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
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
