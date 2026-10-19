#!/bin/bash
#
# Regenerate the README screenshots in screenshots/ from a fresh build.
#
# Launches a second copy of the app next to any installed one and drives it only
# through Accessibility (opening its status item, pressing menu items), never
# with synthetic mouse clicks or keys, so nothing lands on other windows. The
# terminal running it needs Accessibility and Screen Recording access. Each
# screen is captured twice, in the light appearance (menu.png) and in Dark Mode
# (menu-dark.png): the script switches the system appearance and puts the
# user's own back when it exits.
#
# The build is the development app (com.wiltodelta.translatelikeme.dev, its own
# settings domain), and every value the images show that is personal or would
# change its settings is overridden for this launch only, through the argument
# domain (-key value): the language pairs and Rewrite presets with their writing
# styles (the repository is public), and the pane Settings opens on.
# Nothing should be written back; the domain is exported first and imported
# again on exit all the same, because one write on a pane's render once put the
# sample presets into the settings (2026-10-11, when builds shared the
# installed app's domain).
# build.sh stamps the latest tag, so the build raises no update alert.

set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="Translate Like Me.app"
EXECUTABLE="$PWD/$APP_DIR/Contents/MacOS/TranslateLikeMe"
OUT="screenshots"
WORK=$(mktemp -d)
# Two sample pairs, Russian-English on ⌥⌘F with a sample style and a plain
# Russian-English on ⌥⌘G, as the JSON Settings.languagePairs stores, passed as
# an old-style plist <data> value.
# Two sample Rewrite presets, Work on ⌥⌘J and Friends on ⌥⌘K, each with a
# sample style, as the JSON Settings.rewritePresets stores.
SAMPLE_PRESETS='[{"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","shortcut":{"keyCode":38,"modifiers":2304},"style":"Clear and polite, short paragraphs."},{"id":"9F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Friends","shortcut":{"keyCode":40,"modifiers":2304},"style":"Casual, short sentences, no emoji."}]'
SAMPLE_PAIRS='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","shortcut":{"keyCode":3,"modifiers":2304},"style":"Casual and friendly, short sentences."},{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","shortcut":{"keyCode":5,"modifiers":2304},"style":""}]'

# --- Build ----------------------------------------------------------------------

pkill -f "$EXECUTABLE" 2>/dev/null || true
./build.sh >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }

# --- Helper: window lookup and backdrop ------------------------------------------

cat >"$WORK/helper.swift" <<'SWIFT'
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// menu <pid>                -> "x y w h" of the pid's open menu window
// named <pid> <title>       -> "x y w h" of the on-screen window with that title
// menubar                   -> the menu bar height in points
// backdrop <x> <y> <w> <h>   -> show a plain backdrop window there (screen points,
//                              top-left origin) until killed
// pointer [<x> <y>]         -> print the pointer position (top-left origin), or move it
// capture <pid> <backdrop pid> <target x y w h> <capture x y w h> <file>
//                          -> composite only the still-open target and backdrop
let args = CommandLine.arguments

// On-screen windows, front to back.
func onScreen() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

func windows(_ pid: Int32) -> [[String: Any]] {
    onScreen().filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
}

func frame(_ w: [String: Any]) -> CGRect {
    CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)!
}

func printFrame(_ w: [String: Any]) {
    let f = frame(w)
    print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
}

func backdropColor() -> NSColor {
    var color = NSColor.windowBackgroundColor
    NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
        color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            .blended(withFraction: 0.07, of: .black)!.withAlphaComponent(1)
    }
    return color
}

switch args[1] {
case "menu":
    // Menus draw at the pop-up menu level (101); the status item sits at 25.
    if let w = windows(Int32(args[2])!).first(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) > 25 }) {
        printFrame(w)
    }
case "named":
    if let w = windows(Int32(args[2])!).first(where: { ($0[kCGWindowName as String] as? String) == args[3] }) {
        printFrame(w)
    }
case "menubar":
    let screen = NSScreen.screens[0]
    print(Int(screen.frame.maxY - screen.visibleFrame.maxY))
case "backdrop":
    let (x, y, w, h) = (Double(args[2])!, Double(args[3])!, Double(args[4])!, Double(args[5])!)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let screenHeight = NSScreen.screens[0].frame.height
    let window = NSWindow(contentRect: NSRect(x: x, y: screenHeight - y - h, width: w, height: h),
                          styleMask: .borderless, backing: .buffered, defer: false)
    // Opaque, so nothing behind it shows through, and a shade darker than the
    // window, so its edge reads against the margin.
    window.isOpaque = true
    window.backgroundColor = backdropColor()
    window.level = .normal // front of the ordinary app windows, below the menu
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    app.run()
case "pointer":
    if args.count == 4 {
        CGWarpMouseCursorPosition(CGPoint(x: Double(args[2])!, y: Double(args[3])!))
    } else {
        let point = CGEvent(source: nil)!.location
        print(Int(point.x), Int(point.y))
    }
case "capture":
    let (pid, backdrop) = (Int32(args[2])!, Int32(args[3])!)
    let targetRect = CGRect(x: Double(args[4])!, y: Double(args[5])!, width: Double(args[6])!, height: Double(args[7])!)
    let rect = CGRect(x: Double(args[8])!, y: Double(args[9])!, width: Double(args[10])!, height: Double(args[11])!)
    let screen = NSScreen.screens[0]
    let scale = screen.backingScaleFactor
    let background = backdropColor().cgColor
    func matchesTarget(_ window: [String: Any]) -> Bool {
        let f = frame(window)
        return window[kCGWindowOwnerPID as String] as? Int32 == pid
            && abs(f.minX - targetRect.minX) < 1 && abs(f.minY - targetRect.minY) < 1
            && abs(f.width - targetRect.width) < 1 && abs(f.height - targetRect.height) < 1
    }
    guard let target = onScreen().first(where: matchesTarget),
          let targetID = target[kCGWindowNumber as String] as? UInt32 else {
        FileHandle.standardError.write(Data("The target window closed or moved before capture.\n".utf8))
        exit(1)
    }
    let candidates = onScreen().filter { window in
        let owner = window[kCGWindowOwnerPID as String] as? Int32
        return (owner == pid || owner == backdrop) && frame(window).intersects(rect)
    }
    let ids = Set(candidates.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw NSError(domain: "Capture", code: 1)
            }
            let included = content.windows.filter { ids.contains($0.windowID) }
            guard included.contains(where: { $0.windowID == targetID }),
                  included.contains(where: {
                      $0.owningApplication?.processID == backdrop && $0.frame.contains(targetRect)
                  }) else {
                throw NSError(domain: "Capture", code: 2)
            }
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB
            config.backgroundColor = background
            let filter = SCContentFilter(display: display, including: included)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard onScreen().contains(where: { window in
                window[kCGWindowNumber as String] as? UInt32 == targetID && matchesTarget(window)
            }) else { throw NSError(domain: "Capture", code: 5) }
            let output = URL(fileURLWithPath: args[12])
            guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString,
                                                               1, nil) else { throw NSError(domain: "Capture", code: 3) }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw NSError(domain: "Capture", code: 4) }
            print("Target: \(targetRect); composite \(Int(rect.width))x\(Int(rect.height)) pt, "
                  + "scale \(scale), \(included.count) windows")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Capture failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
default:
    exit(2)
}
SWIFT
swiftc -O "$WORK/helper.swift" -o "$WORK/helper" 2>"$WORK/helper.log" || { cat "$WORK/helper.log"; exit 1; }
helper() { "$WORK/helper" "$@"; }

# --- Accessibility driving -------------------------------------------------------

# launch <pane>: a fresh copy with Settings set to open on <pane> (0 General, 1
# Translation, 2 Rewrite), since switching panes in the window would write the choice back.
# -n: a new instance even if an earlier one is still quitting.
# The keys are Settings.Key.languagePairs, .rewritePresets, .provider and
# SettingsTabViewController.lastPaneKey; they name this script, since a renamed
# key would put the real settings into a public image. With the pairs overridden
# the launch also writes none of its own and moves no old style into them.
PID=""
launch() {
    [ -n "$PID" ] && { kill "$PID"; sleep 1; }
    local dictation_enabled=NO
    if [ "${2:-}" = settings ]; then dictation_enabled=YES; fi
    local arguments=(-settingsSelectedPane "$1" -provider anthropic
        -dictationEnabled "$dictation_enabled" -didCompleteFirstRun YES
        -dictationShortcut '<7b226b6579436f6465223a36312c226d6f64696669657273223a323034387d>'
        -languagePairs "<$(printf '%s' "$SAMPLE_PAIRS" | xxd -p | tr -d '\n')>"
        -rewritePresets "<$(printf '%s' "$SAMPLE_PRESETS" | xxd -p | tr -d '\n')>")
    if [ -n "${2:-}" ]; then arguments+=(-dictationPreview "$2"); fi
    open -n "$APP_DIR" --args "${arguments[@]}"
    PID=""
    for _ in $(seq 1 20); do
        PID=$(pgrep -f "$EXECUTABLE" | head -1 || true)
        [ -n "$PID" ] && return 0
        sleep 0.5
    done
    echo "The app did not start."; exit 1
}

ax() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to $1"; }
STATUS_ITEM='menu bar item 1 of menu bar 2'

# Pressing a status item returns only once its menu closes, so it runs in the
# background and the menu window is polled for.
open_menu() {
    for _ in 1 2 3; do
        ax "click $STATUS_ITEM" >/dev/null 2>&1 &
        for _ in $(seq 1 10); do
            [ -n "$(helper menu "$PID")" ] && return 0
            sleep 0.3
        done
    done
    echo "The menu did not open."; return 1
}
close_menu() {
    ax "perform action \"AXCancel\" of menu 1 of $STATUS_ITEM" >/dev/null 2>&1 || true
    sleep 0.5
}
# measure_menu: the open menu's frame into X Y W H. A menu that closed in the
# meantime leaves nothing to read, and a bare read would end the script
# silently under set -e.
measure_menu() {
    read -r X Y W H < <(helper menu "$PID") ||
        { echo "The menu closed before it was measured; rerun with the Mac left alone."; exit 1; }
}

# Status-bar menus follow the menu bar's appearance, not the app's, so only the
# system-wide switch turns the menu dark too.
appearance() {
    osascript -e "tell application \"System Events\" to tell appearance preferences to $1"
}
ORIGINAL_DARK=$(appearance 'get dark mode')

# A pointer resting over a menu item or control would draw it highlighted, so
# the pointer waits at the screen's left edge (no hot corner there) and is put
# back afterwards. Moving it is not a click: nothing receives an event.
POINTER=$(helper pointer)
helper pointer 2 400

# The development build's domain (build.sh); backed up anyway, since a run
# overrides its settings.
DOMAIN=com.wiltodelta.translatelikeme.dev
defaults export "$DOMAIN" "$WORK/defaults.plist"

BACKDROP_PID=""
cleanup() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null && sleep 1
    defaults import "$DOMAIN" "$WORK/defaults.plist" || true
    appearance "set dark mode to $ORIGINAL_DARK" >/dev/null || true
    helper pointer $POINTER
    [ -n "$BACKDROP_PID" ] && kill "$BACKDROP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Menus and windows are Liquid Glass: a single-window capture renders them
# without what sits behind them, as flat gray. So every screenshot puts a plain
# backdrop under the window and composites just those windows with a MARGIN of
# backdrop on each side, window shadow included. The menu keeps space above it,
# filled by the opaque backdrop. ScreenCaptureKit excludes the system menu bar,
# alerts, the Dock and unrelated windows. Verify the exact target frame before
# and after capture, since activation can resize Settings.
MARGIN=20
MENU_BAR=$(helper menubar)
show_backdrop() {
    "$WORK/helper" backdrop $(($1 - 2 * MARGIN)) $(($2 - 2 * MARGIN)) $(($3 + 4 * MARGIN)) $(($4 + 4 * MARGIN)) &
    BACKDROP_PID=$!
    sleep 1.2
}
# capture_frame <name> <x> <y> <w> <h>: the window's frame in screen points. A
# window whose top margin reaches the menu bar (the menu) is captured up through
# it. ScreenCaptureKit includes only this app and the opaque backdrop, so system
# alerts, the Dock and unrelated windows cannot leak into a public image.
capture_frame() {
    local top=$((MARGIN < $3 - MENU_BAR ? MARGIN : $3 - MENU_BAR))
    local region=("$(($2 - MARGIN))" "$(($3 - top))" "$(($4 + 2 * MARGIN))" "$(($5 + top + MARGIN))")
    local shot_region=("${region[@]}")
    [ "$top" -lt "$MARGIN" ] && shot_region=("${region[0]}" 0 "${region[2]}" "$(($3 + $5 + MARGIN))")
    local shot="$WORK/$1.png"
    helper capture "$PID" "$BACKDROP_PID" "$2" "$3" "$4" "$5" "${shot_region[@]}" "$shot"
    kill "$BACKDROP_PID"; wait "$BACKDROP_PID" 2>/dev/null || true; BACKDROP_PID=""
    mv "$shot" "$OUT/$1.png"
    echo "Captured $OUT/$1.png"
}

# --- Screens ---------------------------------------------------------------------

# capture_settings <window title> <name>: open Settings from the menu and capture it.
capture_settings() {
    ax "click menu item \"Settings…\" of menu 1 of $STATUS_ITEM" >/dev/null
    local frame=""
    for _ in $(seq 1 20); do
        frame=$(helper named "$PID" "$1")
        [ -n "$frame" ] && break
        sleep 0.2
    done
    [ -n "$frame" ] || { echo "The settings window did not open on $1."; exit 1; }
    local stable=NO latest=""
    for _ in 1 2 3; do
        read -r SX SY SW SH <<<"$frame"
        show_backdrop "$SX" "$SY" "$SW" "$SH"
        ax 'set frontmost to true' >/dev/null # above the backdrop, key so controls render active
        sleep 1
        latest=$(helper named "$PID" "$1")
        if [ "$latest" = "$frame" ]; then stable=YES; break; fi
        kill "$BACKDROP_PID"; wait "$BACKDROP_PID" 2>/dev/null || true; BACKDROP_PID=""
        frame="$latest"
        [ -n "$frame" ] || { echo "The settings window closed during capture."; exit 1; }
    done
    [ "$stable" = YES ] || { echo "The settings window did not settle."; exit 1; }
    capture_frame "$2" "$SX" "$SY" "$SW" "$SH"
}

# capture_all <dark mode true|false> <file suffix>: every screen in one appearance.
capture_all() {
    appearance "set dark mode to $1" >/dev/null
    sleep 2 # the menu bar and windows redraw
    launch 0 settings
    # The first open starts the engine check; the reopen shows its result.
    open_menu
    sleep 2 # the engine check
    measure_menu
    close_menu
    show_backdrop "$X" "$Y" "$W" "$H"
    open_menu
    sleep 0.5
    measure_menu
    capture_frame "menu$2" "$X" "$Y" "$W" "$H"
    capture_settings General "general$2"

    launch 1
    open_menu
    capture_settings Translation "settings$2"

    launch 2
    open_menu
    capture_settings Rewrite "rewrite$2"

    # Shipping indicator content with synthetic states, without microphone access.
    for state in recording recognizing; do
        launch 0 "$state"
        local frame=""
        for _ in $(seq 1 20); do
            frame=$(helper named "$PID" Dictation)
            [ -n "$frame" ] && break
            sleep 0.2
        done
        [ -n "$frame" ] || { echo "Dictation indicator did not appear."; exit 1; }
        read -r SX SY SW SH <<< "$frame"
        show_backdrop "$SX" "$SY" "$SW" "$SH"
        capture_frame "dictation-$state$2" "$SX" "$SY" "$SW" "$SH"
    done
}

case "${CAPTURE_APPEARANCE:-both}" in
    light) capture_all false "" ;;
    dark) capture_all true -dark ;;
    both) capture_all false ""; capture_all true -dark ;;
    *) echo "CAPTURE_APPEARANCE must be light, dark, or both." >&2; exit 2 ;;
esac

# The website's link preview lays the new menu screenshot beside the tagline.
uv run scripts/make-og-image.py
