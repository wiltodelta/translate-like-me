#!/bin/bash
#
# Regenerate the README screenshots in screenshots/ from a fresh build.
#
# Launches a second copy of the app next to any installed one and drives it only
# through Accessibility (opening its status item, pressing menu items), never
# with synthetic mouse clicks or keys, so nothing lands on other windows. The
# terminal running it needs Accessibility and Screen Recording access. Captures
# follow the current system appearance.
#
# The copy reads the real settings domain, so every value the images show that
# is personal or would change the user's settings is overridden for this launch
# only, through the argument domain (-key value): the writing style (the
# repository is public) and the pane Settings opens on. Nothing is written back.
# build.sh stamps the latest tag, so the build raises no update alert.

set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="Translate Like Me.app"
EXECUTABLE="$PWD/$APP_DIR/Contents/MacOS/TranslateLikeMe"
OUT="screenshots"
WORK=$(mktemp -d)
SAMPLE_STYLE="Casual and friendly, short sentences."

# --- Build ----------------------------------------------------------------------

pkill -f "$EXECUTABLE" 2>/dev/null || true
./build.sh >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }

# --- Helper: window lookup and backdrop ------------------------------------------

cat >"$WORK/helper.swift" <<'SWIFT'
import AppKit
import CoreImage

// menu <pid>                -> "x y w h" of the pid's open menu window
// named <pid> <title>       -> "x y w h" of the on-screen window with that title
// menubar                   -> the menu bar height in points
// backdrop <x> <y> <w> <h>  -> show a plain backdrop window there (screen points,
//                              top-left origin) until killed
// pad <png> <top>           -> add <top> points above the image in its top-left color
// pointer [<x> <y>]         -> print the pointer position (top-left origin), or move it
// clear <pid> <backdrop pid> <x> <y> <w> <h> -> exit 1 unless, front to back, only
//                              the app's windows cover that rect above the backdrop
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
    app.effectiveAppearance.performAsCurrentDrawingAppearance {
        window.backgroundColor = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            .blended(withFraction: 0.07, of: .black)!.withAlphaComponent(1)
    }
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
case "clear":
    let (pid, backdrop) = (Int32(args[2])!, Int32(args[3])!)
    let rect = CGRect(x: Double(args[4])!, y: Double(args[5])!, width: Double(args[6])!, height: Double(args[7])!)
    var sawApp = false
    for w in onScreen() {
        guard frame(w).intersects(rect), (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        // The Dock spans the whole screen at layer 20, transparent but for the
        // Dock itself at the screen edge.
        if w[kCGWindowOwnerName as String] as? String == "Dock" { continue }
        let owner = w[kCGWindowOwnerPID as String] as? Int32
        if owner == backdrop { exit(sawApp ? 0 : 1) }
        if owner == pid { sawApp = true; continue }
        FileHandle.standardError.write(Data("\(w[kCGWindowOwnerName as String] ?? "?") covers the capture\n".utf8))
        exit(1)
    }
    exit(1)
case "pad":
    let url = URL(fileURLWithPath: args[2])
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: url))!
    let image = CIImage(bitmapImageRep: rep)!
    let top = (CGFloat(Double(args[3])!) * CGFloat(rep.pixelsWide) / rep.size.width).rounded()
    // Sample the captured backdrop rather than recompute its color: the capture
    // passes through the display's color management.
    let fill = rep.colorAt(x: 4, y: 4)!.usingColorSpace(.sRGB)!
    let canvas = CGRect(x: 0, y: 0, width: image.extent.width, height: image.extent.height + top)
    let background = CIImage(color: CIColor(color: fill)!).cropped(to: canvas)
    try! CIContext().writePNGRepresentation(of: image.composited(over: background), to: url, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
default:
    exit(2)
}
SWIFT
swiftc -O "$WORK/helper.swift" -o "$WORK/helper" 2>"$WORK/helper.log" || { cat "$WORK/helper.log"; exit 1; }
helper() { "$WORK/helper" "$@"; }

# --- Accessibility driving -------------------------------------------------------

# -n: a new instance even while the installed copy (same bundle id) runs.
# The keys are Settings.Key.style and SettingsTabViewController.lastPaneKey (1 is
# the Translation pane); both name this script, since a renamed key would put
# the real writing style into a public image.
open -n "$APP_DIR" --args -style "$SAMPLE_STYLE" -settingsSelectedPane 1
PID=""
for _ in $(seq 1 20); do
    PID=$(pgrep -f "$EXECUTABLE" | head -1 || true)
    [ -n "$PID" ] && break
    sleep 0.5
done
[ -n "$PID" ] || { echo "The app did not start."; exit 1; }

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

# A pointer resting over a menu item or control would draw it highlighted, so
# the pointer waits at the screen's left edge (no hot corner there) and is put
# back afterwards. Moving it is not a click: nothing receives an event.
POINTER=$(helper pointer)
helper pointer 2 400

BACKDROP_PID=""
cleanup() {
    helper pointer $POINTER
    [ -n "$BACKDROP_PID" ] && kill "$BACKDROP_PID" 2>/dev/null
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Menus and windows are Liquid Glass: a single-window capture renders them
# without what sits behind them, as flat gray. So every screenshot puts a plain
# backdrop under the window and captures that screen region with a MARGIN of
# backdrop on each side, window shadow included. The menu hangs right under the
# menu bar, so the top margin is taken only down to the menu bar and the rest is
# filled in the backdrop's color. Nothing else on screen reaches the image.
MARGIN=20
MENU_BAR=$(helper menubar)
show_backdrop() {
    "$WORK/helper" backdrop $(($1 - 2 * MARGIN)) $(($2 - 2 * MARGIN)) $(($3 + 4 * MARGIN)) $(($4 + 4 * MARGIN)) &
    BACKDROP_PID=$!
    sleep 1.2
}
# capture_region <name> <x> <y> <w> <h>: the window's frame in screen points.
# The region is checked before and after the capture, and the image kept only
# if both pass: a window raised meanwhile (the Mac is in use) would put its
# contents, often private, into a public image.
capture_region() {
    local top=$((MARGIN < $3 - MENU_BAR ? MARGIN : $3 - MENU_BAR))
    local region=("$(($2 - MARGIN))" "$(($3 - top))" "$(($4 + 2 * MARGIN))" "$(($5 + top + MARGIN))")
    local shot="$WORK/$1.png"
    helper clear "$PID" "$BACKDROP_PID" "${region[@]}" &&
        screencapture -x -R"$(IFS=,; echo "${region[*]}")" "$shot" &&
        helper clear "$PID" "$BACKDROP_PID" "${region[@]}" ||
        { echo "Another window covered $1; rerun with the Mac left alone."; exit 1; }
    kill "$BACKDROP_PID"; wait "$BACKDROP_PID" 2>/dev/null || true; BACKDROP_PID=""
    [ "$top" -lt "$MARGIN" ] && helper pad "$shot" $((MARGIN - top))
    mv "$shot" "$OUT/$1.png"
    echo "Captured $OUT/$1.png"
}

# --- Screens ---------------------------------------------------------------------

# The first open starts the engine check; the reopen shows its result.
open_menu
sleep 2 # the engine check
read -r X Y W H < <(helper menu "$PID")
close_menu
show_backdrop "$X" "$Y" "$W" "$H"
open_menu
sleep 0.5
read -r X Y W H < <(helper menu "$PID")
capture_region menu "$X" "$Y" "$W" "$H"

ax "click menu item \"Settings…\" of menu 1 of $STATUS_ITEM" >/dev/null
SETTINGS=""
for _ in $(seq 1 20); do
    SETTINGS=$(helper named "$PID" "Translation")
    [ -n "$SETTINGS" ] && break
    sleep 0.2
done
[ -n "$SETTINGS" ] || { echo "The settings window did not open on Translation."; exit 1; }
read -r SX SY SW SH <<<"$SETTINGS"
show_backdrop "$SX" "$SY" "$SW" "$SH"
ax 'set frontmost to true' >/dev/null # above the backdrop, key so controls render active
sleep 1
capture_region settings "$SX" "$SY" "$SW" "$SH"
