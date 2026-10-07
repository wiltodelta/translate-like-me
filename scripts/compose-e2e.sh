#!/bin/bash
#
# End-to-end check of the compose and translate shortcuts in a real app.
#
# Builds the app, launches a second copy next to any installed one with sample
# settings passed through the argument domain (nothing is written to the real
# settings), types fixture notes into a new TextEdit document, selects them,
# presses the compose shortcut, and waits for the document to change. Then it
# presses the translate shortcut on the result and waits again. The sample
# shortcuts use ⌃⌥⌘ so they never collide with an installed copy's.
#
# Needs Accessibility for the terminal (to drive System Events) and for the
# built app (to copy and paste the selection; an ad hoc build asks again after
# every rebuild), the selected engine signed in, and a Mac left alone while it
# runs: it sends keystrokes to the frontmost app.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="Translate Like Me.app"
EXECUTABLE="$PWD/$APP_DIR/Contents/MacOS/TranslateLikeMe"
# ⌃⌥⌘J composes into English; ⌃⌥⌘T translates Russian <-> English.
# Carbon modifiers: cmdKey 256 + optionKey 2048 + controlKey 4096 = 6400.
TARGETS='[{"id":"9F9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","shortcut":{"keyCode":38,"modifiers":6400},"style":""}]'
PAIRS='[{"id":"AF9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","shortcut":{"keyCode":17,"modifiers":6400},"style":""}]'
NOTES="эээ короче надо написать Пете что отчёт будет в четверг а не в среду и спросить успеет ли он посмотреть до понедельника"
TIMEOUT=90

hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

pkill -f "$EXECUTABLE" 2>/dev/null || true
# An ad hoc build is a new app to Accessibility, so NO_BUILD=1 reuses the bundle
# already granted.
[ "${NO_BUILD:-}" = 1 ] || ./build.sh >/dev/null

open -n "$APP_DIR" --args -provider anthropic \
    -languagePairs "<$(hex "$PAIRS")>" -composeTargets "<$(hex "$TARGETS")>"
PID=""
for _ in $(seq 1 20); do
    PID=$(pgrep -f "$EXECUTABLE" | head -1 || true)
    [ -n "$PID" ] && break
    sleep 0.5
done
[ -n "$PID" ] || { echo "FAIL: the app did not start."; exit 1; }

cleanup() {
    kill "$PID" 2>/dev/null || true
    osascript -e 'tell application "TextEdit" to close (every document whose name starts with "e2e") saving no' \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT
sleep 2 # hotkeys register at launch

# The fixture document's text; empty while it cannot be read.
text() { osascript -e 'tell application "TextEdit" to get text of document "e2e"' 2>/dev/null || true; }

# press <key code>: select all in the frontmost TextEdit document, then press
# the ⌃⌥⌘ shortcut with that key code.
press() {
    osascript <<APPLESCRIPT
tell application "TextEdit"
    activate
    set index of window "e2e" to 1
end tell
delay 0.5
tell application "System Events"
    keystroke "a" using command down
    delay 0.3
    key code $1 using {command down, option down, control down}
end tell
APPLESCRIPT
}

# wait_change <old text>: poll until the document differs from <old text>.
wait_change() {
    for _ in $(seq 1 "$TIMEOUT"); do
        local now
        now=$(text)
        [ -n "$now" ] && [ "$now" != "$1" ] && { printf '%s' "$now"; return 0; }
        sleep 1
    done
    return 1
}

has_cyrillic() { printf '%s' "$1" | perl -CS -ne 'exit(/\p{Cyrillic}/ ? 0 : 1)'; }

osascript -e "tell application \"TextEdit\" to make new document with properties {name:\"e2e\", text:\"$NOTES\"}" \
    >/dev/null

echo "Compose (⌃⌥⌘J) ..."
press 38
COMPOSED=$(wait_change "$NOTES") || { echo "FAIL: compose did not replace the notes in ${TIMEOUT}s."; exit 1; }
echo "  -> $COMPOSED"
has_cyrillic "$COMPOSED" && { echo "FAIL: the message is not in English."; exit 1; }
for fact in Thursday Monday "?"; do
    [[ "$COMPOSED" == *"$fact"* ]] || { echo "FAIL: the message lost \"$fact\"."; exit 1; }
done

echo "Translate (⌃⌥⌘T) ..."
press 17
TRANSLATED=$(wait_change "$COMPOSED") || { echo "FAIL: translate did not replace the text in ${TIMEOUT}s."; exit 1; }
echo "  -> $TRANSLATED"
has_cyrillic "$TRANSLATED" || { echo "FAIL: the translation is not in Russian."; exit 1; }

echo "PASS"
