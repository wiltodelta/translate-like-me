#!/bin/bash
# Read metadata from a running app and its last five minutes of dictation logs.
# No microphone, clipboard, settings or privacy permissions are changed.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [app-pid]" >&2
    exit 2
fi
APP_PID="${1:-}"
if [[ -z "$APP_PID" ]]; then
    APP_PID="$(pgrep -x TranslateLikeMe || true)"
fi
if [[ -z "$APP_PID" || "$APP_PID" == *[!0-9]* ]]; then
    echo "Start one copy of Translate Like Me, or pass its numeric process ID." >&2
    exit 2
fi
EXECUTABLE="$(ps -p "$APP_PID" -o comm=)"
if [[ "$EXECUTABLE" != */Translate\ Like\ Me.app/Contents/MacOS/TranslateLikeMe ]]; then
    echo "The selected process is not the Translate Like Me app bundle." >&2
    exit 2
fi
APP_BUNDLE="${EXECUTABLE%/Contents/MacOS/TranslateLikeMe}"
PLIST="$APP_BUNDLE/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
case "$BUNDLE_ID" in
    com.wiltodelta.translatelikeme|com.wiltodelta.translatelikeme.dev) ;;
    *) echo "Unexpected app identity: $BUNDLE_ID" >&2; exit 2 ;;
esac

echo "Translate Like Me dictation diagnostics"
date -u '+Collected: %Y-%m-%dT%H:%M:%SZ'
sw_vers
echo "Architecture: $(uname -m)"
echo "Process: $APP_PID"
echo "Bundle ID: $BUNDLE_ID"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "Executable SHA-256: $(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
echo
echo "Last five minutes, current process, dictation and hotkey metadata only:"
/usr/bin/log show --last 5m --style compact --info --predicate \
    "subsystem == \"com.wiltodelta.translatelikeme\" AND processIdentifier == $APP_PID AND (category == \"dictation\" OR category == \"hotkey\")"
echo
echo "Older releases omit stage metadata. An empty log does not establish the cause."
