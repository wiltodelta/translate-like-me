#!/bin/bash
# Notarize and staple the bundle build.sh produced, then zip it for a release:
#   RELEASE=1 ./build.sh && ./notarize.sh   -> TranslateLikeMe-vX.Y-macOS.zip
#   ./notarize.sh --zip-only                -> the same zip, not notarized (CI branch builds)
#
# Needs the Developer ID signature with a secure timestamp that RELEASE=1 build.sh
# applies, and the team's notarytool credentials stored once in the login
# keychain (the key files are in 1Password, see docs/build-and-release.md):
#   xcrun notarytool store-credentials notary-K2GT9Q4S6U \
#       --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
set -euo pipefail
cd "$(dirname "$0")"

APP="Translate Like Me.app"
PROFILE="${NOTARY_PROFILE:-notary-K2GT9Q4S6U}"
# CI stores the profile in a temporary keychain and names it here.
KEYCHAIN_ARGS=(${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"})
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="TranslateLikeMe-v$VERSION-macOS.zip"

if [[ "${1:-}" != "--zip-only" ]]; then
    # Read into a variable first: under pipefail, grep -q closing the pipe early
    # would fail the pipeline even on a match.
    SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
    grep -q "^Authority=Developer ID Application:" <<<"$SIGNATURE" && grep -q "^Timestamp=" <<<"$SIGNATURE" ||
        { echo "error: $APP needs a timestamped Developer ID signature (RELEASE=1 ./build.sh)" >&2; exit 1; }

    # notarytool takes a zip; the ticket is stapled to the app itself, so the
    # release zip is built afterwards.
    UPLOAD="$(mktemp -d)/upload.zip"
    ditto -c -k --keepParent "$APP" "$UPLOAD"
    xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $PWD/$ZIP"
