#!/bin/bash
#
# Regenerate the README screenshots in screenshots/ from a fresh build.
#
# Launches a second copy of the app next to any installed one and drives it only
# through Accessibility (opening its status item, pressing menu items), with
# guarded numeric keys only for sheet dismissal and no synthetic mouse clicks. The
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
#
# CAPTURE_LANGUAGE=ru (any localization in Resources/Localizable.xcstrings)
# launches the app in that language and writes to CAPTURE_OUT instead, to check
# a localization's layout; the README keeps the English images.

set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="Translate Like Me Dev.app"
EXECUTABLE="$PWD/$APP_DIR/Contents/MacOS/TranslateLikeMe"
LANGUAGE="${CAPTURE_LANGUAGE:-}"
OUT="${CAPTURE_OUT:-screenshots}"
[ -z "$LANGUAGE" ] || [ "$OUT" != screenshots ] ||
    { echo "CAPTURE_LANGUAGE needs a CAPTURE_OUT directory; screenshots/ stays English." >&2; exit 2; }
mkdir -p "$OUT"
WORK=$(mktemp -d)
# Two sample pairs, Russian-English on ⌥⌘F with a sample style and a plain
# Russian-English on ⌥⌘G, as the JSON Settings.languagePairs stores, passed as
# an old-style plist <data> value.
# Two sample Rewrite presets, Work on ⌥⌘J and Friends on ⌥⌘K, each with a
# sample style, as the JSON Settings.rewritePresets stores.
SAMPLE_PRESETS='[{"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","shortcut":{"keyCode":38,"modifiers":2304},"style":"Clear and polite, short paragraphs."},{"id":"9F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Friends","shortcut":{"keyCode":40,"modifiers":2304},"style":"Casual, short sentences, no emoji."}]'
SAMPLE_PAIRS='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","shortcut":{"keyCode":3,"modifiers":2304},"style":"Casual and friendly, short sentences."},{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","shortcut":{"keyCode":5,"modifiers":2304},"style":""}]'

# A synthetic new-profile example alongside the larger custom-profile fixture.
# It uses the same stored shape as the existing screenshot samples.
if [ "${CAPTURE_STARTER_ONLY:-0}" = 1 ]; then
    SAMPLE_PAIRS=$(python3 - "$SAMPLE_PAIRS" <<'PYTHON'
import json
import sys
pairs = json.loads(sys.argv[1])[:1]
pairs[0]["style"] = ""
print(json.dumps(pairs))
PYTHON
)
    SAMPLE_PRESETS=$(python3 - "$SAMPLE_PRESETS" "$LANGUAGE" <<'PYTHON'
import json
from pathlib import Path
import sys
presets = json.loads(sys.argv[1])[:1]
entry = json.loads(Path("Resources/Localizable.xcstrings").read_text())["strings"]["Improve Text"]
presets[0]["name"] = entry["localizations"].get(sys.argv[2], {}).get("stringUnit", {}).get("value", "Improve Text")
presets[0]["style"] = ""
print(json.dumps(presets))
PYTHON
)
fi

# CAPTURE_APPEARANCE=current captures without changing the theme or pointer.
# CAPTURE_ONBOARDING_ONLY=1 with CAPTURE_OUT=<dir> renders the three-screen onboarding
# with synthetic model and permission state, never real downloads or TCC prompts.
# CAPTURE_MODELS_ONLY=1 with CAPTURE_OUT=<dir> checks both model managers.
# CAPTURE_PROVIDERS_ONLY=1 with CAPTURE_OUT=<dir> captures each translation
# engine and a synthetic incompatible-effort state, without translating text.
# CAPTURE_MODEL_KIND=translation|speech limits that pass to one manager.
# CAPTURE_MODEL_INTERACTIONS=0 captures the manager without retesting its dismissal routes.
# CAPTURE_MENU_ONLY=1 refreshes just menu.png and menu-dark.png.
# CAPTURE_ACTIVITY_ONLY=1 captures translation, Rewrite and dictation indicators.
# CAPTURE_RESULTS_ONLY=1 with CAPTURE_OUT=<dir> checks empty, partial and full
# recovery submenus. Its synthetic launch fixtures never call a model or record audio.

# --- Build ----------------------------------------------------------------------

# Quit only the exact development bundle, preserving every other running app.
swift - "$PWD/$APP_DIR" <<'SWIFT'
import AppKit
let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == bundle {
    guard app.terminate() else { fatalError("The development app refused to quit") }
    let deadline = Date().addingTimeInterval(5)
    while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard app.isTerminated else { fatalError("The development app did not quit") }
}
SWIFT
./build.sh >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }

# --- Helper: window lookup and backdrop ------------------------------------------

cat >"$WORK/helper.swift" <<'SWIFT'
import AppKit
import ApplicationServices
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

func captureFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func requireUnlockedSession() {
    let probe = Process()
    let output = Pipe()
    probe.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    probe.arguments = ["-n", "Root", "-d1", "-a"]
    probe.standardOutput = output
    do { try probe.run() } catch { captureFailure("Could not read the console session") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
    let root = (plist as? [String: Any]) ?? (plist as? [[String: Any]])?.first
    let console = (root?["IOConsoleUsers"] as? [[String: Any]])?
        .first { $0["kCGSSessionOnConsoleKey"] as? Bool == true }
    guard probe.terminationStatus == 0, let console else {
        captureFailure("Could not read the active console session")
    }
    guard console["CGSSessionScreenIsLocked"] as? Bool != true,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else {
        captureFailure("The console session is locked")
    }
}

// SwiftUI buttons are below AX children that System Events does not expose.
func axAttribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
    return value
}

func axMatches(_ node: AXUIElement, key: String, value: String, visited: inout Int) -> [AXUIElement] {
    visited += 1
    guard visited < 10000 else { captureFailure("The AX walk exceeded its bound") }
    let keys = key == "text" ? [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] : [key]
    var matches = keys.contains { axAttribute(node, $0) as? String == value } ? [node] : []
    for child in axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        matches += axMatches(child, key: key, value: value, visited: &visited)
    }
    return matches
}

switch args[1] {
case "reset-picker":
    NSApplication.shared.setActivationPolicy(.prohibited)
    requireUnlockedSession()
    let app = AXUIElementCreateApplication(Int32(args[2])!)
    guard let roots = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
        captureFailure("No windows for picker reset")
    }
    var visited = 0
    let controls = roots.flatMap { axMatches($0, key: kAXIdentifierAttribute, value: args[3], visited: &visited) }
    guard controls.count == 1,
          AXUIElementPerformAction(controls[0], kAXPressAction as CFString) == .success else {
        captureFailure("Could not open picker: \(args[3])")
    }
    var menuItem: AXUIElement?
    for _ in 0..<20 {
        var count = 0
        menuItem = axMatches(app, key: kAXRoleAttribute, value: kAXMenuItemRole, visited: &count).first {
            (axAttribute($0, kAXTitleAttribute) as? String)?.hasPrefix(args[4]) == true
        }
        if menuItem != nil { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let menuItem, AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success else {
        captureFailure("Could not choose Default")
    }
    var reset = false
    var values: [String] = []
    for _ in 0..<40 {
        var count = 0
        let current = axMatches(app, key: kAXIdentifierAttribute, value: args[3], visited: &count)
        values = current.map { String(describing: axAttribute($0, kAXValueAttribute)) }
        if current.isEmpty || current.contains(where: {
            (axAttribute($0, kAXValueAttribute) as? String)?.hasPrefix(args[4]) == true
        }) { reset = true; break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard reset else { captureFailure("Picker did not reset: \(values)") }
    print("Verified picker reset: \(args[3])")
case "press-id", "dismiss-id", "expect", "expect-absent", "expect-id-absent", "expect-disabled", "expect-enabled":
    NSApplication.shared.setActivationPolicy(.prohibited)
    let app = AXUIElementCreateApplication(Int32(args[2])!)
    let key = ["expect", "expect-absent"].contains(args[1]) ? "text" : kAXIdentifierAttribute
    var visited = 0
    var rawWindows: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
    guard error == .success, let windows = rawWindows as? [AXUIElement] else {
        captureFailure("AXWindows failed: \(error.rawValue), trusted: \(AXIsProcessTrusted())")
    }
    let matches = windows.flatMap { axMatches($0, key: key, value: args[3], visited: &visited) }
    if args[1] == "expect-absent" || args[1] == "expect-id-absent" {
        guard matches.isEmpty else { captureFailure("Unexpected AX text: \(args[3])") }
        print("Verified absent: \(args[3])")
        exit(0)
    }
    guard !matches.isEmpty, args[1] == "expect" || matches.count == 1 else {
        captureFailure("Expected an AX target for \(args[3]), found \(matches.count) in \(visited) elements")
    }
    let node = matches[0]
    if args[1] == "press-id" || args[1] == "dismiss-id" {
        requireUnlockedSession()
        guard axAttribute(node, kAXEnabledAttribute) as? Bool == true else {
            captureFailure("The AX target is disabled: \(args[3])")
        }
        let result = AXUIElementPerformAction(node, kAXPressAction as CFString)
        if args[1] == "dismiss-id" {
            // A modal's destruction can invalidate its AXPress reply. Prove
            // dismissal from the new tree rather than retrying the mutation.
            var dismissed = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.05)
                var count = 0
                guard let current = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
                    captureFailure("Could not read windows after dismissal")
                }
                if current.flatMap({ axMatches($0, key: key, value: args[3], visited: &count) }).isEmpty {
                    dismissed = true
                    break
                }
            }
            guard dismissed else { captureFailure("The AX target did not dismiss: \(result.rawValue)") }
        } else if result != .success {
            captureFailure("AXPress failed for \(args[3]): \(result.rawValue)")
        }
    } else if args[1] == "expect-enabled" {
        guard axAttribute(node, kAXEnabledAttribute) as? Bool == true else { captureFailure("Expected enabled control") }
    } else if args[1] == "expect-disabled" {
        guard axAttribute(node, kAXEnabledAttribute) as? Bool == false else { captureFailure("Expected disabled control") }
    }
    print("Verified \(args[1]): \(args[3])")
case "key":
    NSApplication.shared.setActivationPolicy(.prohibited)
    let pid = Int32(args[2])!
    requireUnlockedSession()
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        captureFailure("The target lost focus before the key")
    }
    guard let key = UInt16(args[3]) else { captureFailure("Invalid key code") }
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    command.arguments = ["-e", """
        with timeout of 5 seconds
            tell application "System Events"
                if frontmost of (first process whose unix id is \(pid)) is not true then error "The target lost focus"
                key code \(key)
            end tell
        end timeout
        """]
    try command.run()
    command.waitUntilExit()
    guard command.terminationStatus == 0 else { captureFailure("The guarded key failed") }
case "press-remove":
    NSApplication.shared.setActivationPolicy(.prohibited)
    requireUnlockedSession()
    let app = AXUIElementCreateApplication(Int32(args[2])!)
    guard let windows = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
        captureFailure("No windows for removal confirmation")
    }
    for identifier in args.dropFirst(3) {
        var visited = 0
        let matches = windows.flatMap { axMatches($0, key: kAXIdentifierAttribute, value: identifier, visited: &visited) }
        if let button = matches.first, axAttribute(button, kAXEnabledAttribute) as? Bool == true {
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                captureFailure("Could not open removal confirmation")
            }
            print("Opened removal confirmation: \(identifier)")
            exit(0)
        }
    }
    exit(4) // No downloaded model available for the confirmation-only check.
case "screen":
    let frame = NSScreen.screens[0].frame
    print(Int(frame.width), Int(frame.height))
case "menus":
    let menus = windows(Int32(args[2])!).filter { ($0[kCGWindowLayer as String] as? Int ?? 0) > 25 }
    guard !menus.isEmpty else { exit(1) }
    let bounds = menus.reduce(CGRect.null) { $0.union(frame($1)) }
    print(Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height))
case "menu":
    // Menus draw at the pop-up menu level (101); the status item sits at 25.
    if let w = windows(Int32(args[2])!).first(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) > 25 }) {
        printFrame(w)
    }
case "front-window":
    if let w = windows(Int32(args[2])!).first(where: { frame($0).width > 100 }) { printFrame(w) }
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

# localized <English>: the title the app shows in CAPTURE_LANGUAGE, read from the
# built bundle, for the menu items and windows the script finds by title.
localized() {
    if [ -z "$LANGUAGE" ] || [ "$LANGUAGE" = en ]; then printf '%s' "$1"; return; fi
    # plutil -extract interprets periods as key-path separators. UI sentences
    # need exact dictionary lookup, including punctuation and placeholders.
    python3 - "$APP_DIR/Contents/Resources/$LANGUAGE.lproj/Localizable.strings" "$1" <<'PYTHON'
import json
import subprocess
import sys
data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", sys.argv[1]])
sys.stdout.write(json.loads(data)[sys.argv[2]])
PYTHON
}

# --- Accessibility driving -------------------------------------------------------

# launch <pane> [<dictation preview>] [<provider>] [<results preview>]: a fresh copy
# with Settings set to open on <pane> (stable IDs: 0 General, 1 Translation,
# 2 Rewrite, 3 Dictation), independent of their visual order in the toolbar.
# -n: a new instance even if an earlier one is still quitting.
# The keys are Settings.Key.languagePairs, .rewritePresets, .provider, localModel and
# SettingsTabViewController.lastPaneKey; they name this script, since a renamed
# key would put the real settings into a public image. With the pairs overridden
# the launch also writes none of its own and moves no old style into them.
PID=""
launch() {
    if [ -n "$PID" ]; then
        local previous_pid="$PID"
        kill "$previous_pid" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$previous_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$previous_pid" 2>/dev/null; then
            echo "The previous development process did not exit." >&2
            exit 1
        fi
        echo "Previous development PID $previous_pid exited."
        PID=""
    fi
    local dictation_enabled=NO completed_first_run=YES pairs_json="$SAMPLE_PAIRS"
    local speech_model="${CAPTURE_DICTATION_MODEL:-turbo}"
    if [ "${2:-}" = settings ]; then dictation_enabled=YES; fi
    if [ "${CAPTURE_ONBOARDING_ONLY:-0}" = 1 ]; then
        dictation_enabled=NO
        completed_first_run=NO
        speech_model="${CAPTURE_DICTATION_MODEL:-qwen3ASR}"
    fi
    if [ "${CAPTURE_EMPTY_PAIRS:-0}" = 1 ]; then pairs_json='[]'; fi
    local arguments=(-settingsSelectedPane "$1" -provider "${3:-anthropic}" -localModel "${CAPTURE_LOCAL_MODEL:-translategemma-12b}"
        -dictationEnabled "$dictation_enabled" -dictationModel "$speech_model" -didCompleteFirstRun "$completed_first_run"
        -dictationShortcut '<7b226b6579436f6465223a36312c226d6f64696669657273223a323034387d>'
        -languagePairs "<$(printf '%s' "$pairs_json" | xxd -p | tr -d '\n')>"
        -rewritePresets "<$(printf '%s' "$SAMPLE_PRESETS" | xxd -p | tr -d '\n')>")
    if [ "${CAPTURE_ONBOARDING_ONLY:-0}" = 1 ]; then
        arguments+=(-onboardingPreview YES -onboardingStage "${CAPTURE_ONBOARDING_STAGE:-preparation}")
    fi
    if [ -n "${4:-}" ]; then arguments+=(-lastResultsPreview "$4"); fi
    if [ -n "${5:-}" ]; then arguments+=(-activityPreview "$5"); fi
    if [ "${CAPTURE_INCOMPATIBLE_EFFORT:-0}" = 1 ]; then
        arguments+=(-harnessModel.anthropic opus -harnessEffort.anthropic synthetic-unsupported)
    fi
    if [ "${CAPTURE_UNKNOWN_EFFORT:-0}" = 1 ]; then
        arguments+=(-harnessModel.anthropic synthetic-unknown -harnessEffort.anthropic low)
    fi
    if [ -n "$LANGUAGE" ]; then arguments+=(-AppleLanguages "($LANGUAGE)"); fi
    if [ -n "${2:-}" ]; then arguments+=(-dictationPreview "$2"); fi
    open -n "$APP_DIR" --args "${arguments[@]}"
    PID=""
    for _ in $(seq 1 20); do
        PID=$(pgrep -f "$EXECUTABLE" | head -1 || true)
        [ -n "$PID" ] && { echo "Launched development PID $PID."; return 0; }
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
    # Current mode observes the system; it never writes another session's theme.
    if [ "${CAPTURE_APPEARANCE:-both}" = current ] && [ "$1" != 'get dark mode' ]; then return; fi
    osascript -e "tell application \"System Events\" to tell appearance preferences to $1"
}
ORIGINAL_DARK=$(appearance 'get dark mode')

# A pointer resting over a menu item or control would draw it highlighted, so
# the pointer waits at the screen's left edge (no hot corner there) and is put
# back afterwards. Moving it is not a click: nothing receives an event.
POINTER=$(helper pointer)
[ "${CAPTURE_APPEARANCE:-both}" = current ] || helper pointer 2 400

# The development build's domain (build.sh); backed up anyway, since a run
# overrides its settings.
DOMAIN=com.wiltodelta.translatelikeme.dev
defaults export "$DOMAIN" "$WORK/defaults.plist"

BACKDROP_PID=""
cleanup() {
    local status=$? restore_failed=0
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$PID" 2>/dev/null; then
            kill -KILL "$PID" 2>/dev/null || true
            sleep 0.2
        fi
    fi
    # defaults import merges and leaves keys added during the capture behind.
    # Replace the entire saved domain only after our app has stopped.
    swift - "$DOMAIN" "$WORK/defaults.plist" "${PID:-0}" <<'SWIFT' || restore_failed=1
import AppKit
import Foundation
if let app = NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[3])!), !app.isTerminated { exit(1) }
let saved = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), format: nil) as! [String: Any]
UserDefaults.standard.setPersistentDomain(saved, forName: CommandLine.arguments[1])
guard UserDefaults.standard.synchronize() else { exit(1) }
SWIFT
    if ! defaults export "$DOMAIN" "$WORK/defaults-after.plist" >/dev/null; then
        restore_failed=1
    elif ! python3 - "$WORK/defaults.plist" "$WORK/defaults-after.plist" <<'PYTHON'
import plistlib
import sys
with open(sys.argv[1], "rb") as stream:
    before = plistlib.load(stream)
with open(sys.argv[2], "rb") as stream:
    after = plistlib.load(stream)
if before != after:
    raise SystemExit("Development preferences differ after restoration")
PYTHON
    then restore_failed=1; fi
    appearance "set dark mode to $ORIGINAL_DARK" >/dev/null || true
    [ "$(appearance 'get dark mode')" = "$ORIGINAL_DARK" ] || restore_failed=1
    [ "${CAPTURE_APPEARANCE:-both}" = current ] || helper pointer $POINTER
    [ -n "$BACKDROP_PID" ] && kill "$BACKDROP_PID" 2>/dev/null
    if [ "$restore_failed" = 0 ]; then
        rm -rf "$WORK"
    else
        echo "Preferences were not restored; backup retained at $WORK/defaults.plist" >&2
        status=1
    fi
    exit "$status"
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
verify_current_appearance() {
    [ -z "${CURRENT_DARK:-}" ] || [ "$(appearance 'get dark mode')" = "$CURRENT_DARK" ] ||
        { echo "The system appearance changed during capture; rerun the affected pass." >&2; exit 1; }
}

capture_frame() {
    verify_current_appearance
    local top=$((MARGIN < $3 - MENU_BAR ? MARGIN : $3 - MENU_BAR))
    local region=("$(($2 - MARGIN))" "$(($3 - top))" "$(($4 + 2 * MARGIN))" "$(($5 + top + MARGIN))")
    local shot_region=("${region[@]}")
    [ "$top" -lt "$MARGIN" ] && shot_region=("${region[0]}" 0 "${region[2]}" "$(($3 + $5 + MARGIN))")
    local shot="$WORK/$1.png"
    helper capture "$PID" "$BACKDROP_PID" "$2" "$3" "$4" "$5" "${shot_region[@]}" "$shot"
    verify_current_appearance
    kill "$BACKDROP_PID"; wait "$BACKDROP_PID" 2>/dev/null || true; BACKDROP_PID=""
    mv "$shot" "$OUT/$1.png"
    echo "Captured $OUT/$1.png"
}

# Read-only captures may retry when another app briefly takes focus. Keys keep
# their own exact-target guard and are never retried into another process.
capture_active_frame() {
    for _ in 1 2 3; do
        [ -n "$BACKDROP_PID" ] || show_backdrop "$2" "$3" "$4" "$5"
        ax 'set frontmost to true' >/dev/null
        sleep 0.1
        if [ "$(ax 'get frontmost')" != true ]; then continue; fi
        capture_frame "$@"
        if [ "$(ax 'get frontmost')" = true ]; then return; fi
    done
    echo "The target could not keep focus during capture." >&2
    return 1
}

# --- Screens ---------------------------------------------------------------------

# capture_settings <window title> <name>: open Settings from the menu and capture it.
capture_settings() {
    ax "click menu item \"$(localized "Settings…")\" of menu 1 of $STATUS_ITEM" >/dev/null
    capture_window "$@"
}

capture_window() {
    local frame=""
    for _ in $(seq 1 20); do
        frame=$(helper named "$PID" "$1")
        [ -n "$frame" ] && break
        sleep 0.2
    done
    [ -n "$frame" ] || { echo "The target window did not open on $1."; exit 1; }
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
        [ -n "$frame" ] || { echo "The target window closed during capture."; exit 1; }
    done
    [ "$stable" = YES ] || { echo "The target window did not settle."; exit 1; }
    capture_active_frame "$2" "$SX" "$SY" "$SW" "$SH"
}

wait_onboarding_control() {
    for _ in $(seq 1 30); do
        if helper expect-enabled "$PID" "$1" >/dev/null 2>&1; then return; fi
        sleep 0.1
    done
    helper expect-enabled "$PID" "$1"
}

# Render the shipping onboarding with synthetic state, never real downloads or permission prompts.
capture_onboarding() {
    appearance "set dark mode to $1" >/dev/null
    sleep 2
    local title stage
    title=$(localized "Welcome to Translate Like Me")
    for stage in ${CAPTURE_ONBOARDING_STAGES:-preparation downloading failed permissions accessibility permissions-ready usage}; do
        CAPTURE_ONBOARDING_STAGE="$stage" launch 3 settings local
        capture_window "$title" "onboarding-$stage$2"
        if [ -n "${CAPTURE_GEOMETRY_HELPER:-}" ]; then
            uv run "$CAPTURE_GEOMETRY_HELPER" geometry --pid "$PID" --state "$stage" \
                > "$OUT/onboarding-$stage$2-geometry.json"
        fi
        if [ "$stage" = preparation ]; then
            helper expect-disabled "$PID" onboarding.continue
            helper expect-enabled "$PID" onboarding.download
            helper press-id "$PID" onboarding.download
            wait_onboarding_control onboarding.continue
            helper press-id "$PID" onboarding.continue
            wait_onboarding_control onboarding.permission
            helper press-id "$PID" onboarding.permission
            wait_onboarding_control onboarding.permission
            helper press-id "$PID" onboarding.permission
            wait_onboarding_control onboarding.permission
            helper press-id "$PID" onboarding.permission
            wait_onboarding_control onboarding.done
            helper press-id "$PID" onboarding.done
        fi
        if [ "$stage" = usage ]; then helper expect-enabled "$PID" onboarding.done; fi
    done
}

# Capture the shipping submenu with all, some or no results, using only synthetic text.
capture_results() {
    local dark="$1" suffix="$2" state
    appearance "set dark mode to $dark" >/dev/null
    sleep 2
    for state in empty partial all; do
        local fixture="$state"
        [ "$state" != empty ] || fixture=""
        launch 0 settings anthropic "$fixture"
        local screen_w screen_h
        read -r screen_w screen_h < <(helper screen)
        show_backdrop 0 0 "$screen_w" "$screen_h"
        open_menu
        measure_menu
        ax "perform action \"AXPress\" of menu item \"$(localized 'Copy Last Result')\" of menu 1 of $STATUS_ITEM" >/dev/null
        sleep 0.7
        local union_x union_y union_w union_h
        read -r union_x union_y union_w union_h < <(helper menus "$PID")
        [ "$union_w" -gt "$W" ] || { echo "The results submenu did not open."; exit 1; }
        verify_current_appearance
        helper capture "$PID" "$BACKDROP_PID" "$X" "$Y" "$W" "$H" \
            "$((union_x - MARGIN))" "$union_y" "$((union_w + 2 * MARGIN))" "$((union_h + MARGIN))" \
            "$OUT/results-$state$suffix.png"
        verify_current_appearance
        echo "Results $state: parent ${W}x${H} pt, combined ${union_w}x${union_h} pt"
        close_menu
        kill "$BACKDROP_PID"; wait "$BACKDROP_PID" 2>/dev/null || true; BACKDROP_PID=""
    done
}

# Exercise both real entry points and dismiss/reopen without mutating downloads.
capture_models() {
    CURRENT_DARK="$1"
    appearance "set dark mode to $1" >/dev/null
    sleep 2
    local pane title kind parent
    for kind in translation speech; do
        if [ -n "${CAPTURE_MODEL_KIND:-}" ] && [ "$CAPTURE_MODEL_KIND" != "$kind" ]; then continue; fi
        if [ "$kind" = translation ]; then pane=1; title=$(localized Translation); parent=settings-local
        else pane=3; title=$(localized Dictation); parent=dictation; fi
        launch "$pane" settings local
        open_menu
        capture_settings "$title" "$parent$2"
        helper press-id "$PID" manage-models
        sleep 1
        helper expect "$PID" "$(localized 'Manage Models…')"
        local frame
        frame=$(helper front-window "$PID")
        read -r SX SY SW SH <<<"$frame"
        capture_active_frame "models-$kind$2" "$SX" "$SY" "$SW" "$SH"
        if [ -n "${CAPTURE_GEOMETRY_TOOL:-}" ]; then
            uv run "$CAPTURE_GEOMETRY_TOOL" geometry --pid "$PID" --state "models-$kind$2" \
                >"$OUT/models-$kind$2.geometry.json"
        fi
        if [ "${CAPTURE_VERIFY_PROTECTION:-0}" = 1 ]; then
            if [ "$kind" = speech ]; then
                helper expect-disabled "$PID" "remove-${CAPTURE_DICTATION_MODEL:-turbo}"
            else
                helper expect-disabled "$PID" "remove-${CAPTURE_LOCAL_MODEL:-translategemma-12b}"
            fi
        fi
        if [ "${CAPTURE_MODEL_INTERACTIONS:-1}" = 0 ]; then continue; fi
        local removal_status=0
        helper press-remove "$PID" remove-gemma-4-e2b remove-translategemma-12b remove-turbo remove-qwen3ASR \
            || removal_status=$?
        if [ "$removal_status" = 0 ]; then
            sleep 0.5
            frame=$(helper front-window "$PID")
            read -r SX SY SW SH <<<"$frame"
            capture_active_frame "models-$kind-removal$2" "$SX" "$SY" "$SW" "$SH"
            if [ -n "${CAPTURE_GEOMETRY_TOOL:-}" ]; then
                uv run "$CAPTURE_GEOMETRY_TOOL" geometry --pid "$PID" --state "models-$kind-removal$2" \
                    >"$OUT/models-$kind-removal$2.geometry.json"
            fi
            helper dismiss-id "$PID" cancel-removal
        elif [ "$removal_status" != 4 ]; then
            return "$removal_status"
        fi
        helper press-id "$PID" models-done
        helper expect-id-absent "$PID" models-done
        helper press-id "$PID" manage-models
        sleep 0.5 # Wait for the sheet's first responder after its animation.
        ax 'set frontmost to true' >/dev/null
        helper key "$PID" 53 # Escape closes the sheet.
        sleep 0.5
        helper expect-id-absent "$PID" models-done
        helper press-id "$PID" manage-models
        sleep 0.5 # Wait for the sheet's first responder after its animation.
        ax 'set frontmost to true' >/dev/null
        helper key "$PID" 36 # Return activates Done.
        sleep 0.5
        helper expect-id-absent "$PID" models-done
    done
}

# Shipping indicator content with synthetic states, without engines or microphone access.
capture_activity() {
    appearance "set dark mode to $1" >/dev/null
    local state indicator name
    for state in translation rewrite recording recognizing; do
        case "$state" in
            translation|rewrite)
                launch 0 "" "" "" "$state"
                if [ "$state" = rewrite ]; then indicator=$(localized Rewrite)
                else indicator=$(localized Translation); fi
                name="$state-progress$2" ;;
            *)
                launch 0 "$state"
                indicator=$(localized Dictation)
                name="dictation-$state$2" ;;
        esac
        local frame=""
        for _ in $(seq 1 20); do
            frame=$(helper named "$PID" "$indicator")
            [ -n "$frame" ] && break
            sleep 0.2
        done
        [ -n "$frame" ] || { echo "Activity indicator did not appear: $state"; exit 1; }
        local stable=NO latest=""
        for _ in 1 2 3; do
            read -r SX SY SW SH <<< "$frame"
            show_backdrop "$SX" "$SY" "$SW" "$SH"
            latest=$(helper named "$PID" "$indicator")
            if [ "$latest" = "$frame" ]; then stable=YES; break; fi
            kill "$BACKDROP_PID"; wait "$BACKDROP_PID" 2>/dev/null || true; BACKDROP_PID=""
            frame="$latest"
            [ -n "$frame" ] || { echo "Activity indicator closed during capture: $state"; exit 1; }
        done
        [ "$stable" = YES ] || { echo "Activity indicator did not settle: $state"; exit 1; }
        capture_frame "$name" "$SX" "$SY" "$SW" "$SH"
        helper dismiss-id "$PID" activity-cancel
        helper expect-id-absent "$PID" activity-cancel
    done
}

# capture_all <dark mode true|false> <file suffix>: every screen in one appearance.
capture_providers() {
    appearance "set dark mode to $1" >/dev/null
    sleep 2
    for provider in ${CAPTURE_PROVIDER_LIST:-anthropic openai grok antigravity local}; do
        launch 1 "" "$provider"
        open_menu
        capture_settings "$(localized Translation)" "provider-$provider$2"
    done
    CAPTURE_INCOMPATIBLE_EFFORT=1 launch 1 "" anthropic
    open_menu
    ax "click menu item \"$(localized "Settings…")\" of menu 1 of $STATUS_ITEM" >/dev/null
    sleep 1
    helper expect "$PID" "$(localized "The saved effort is unavailable for this model. The CLI default will be used.")"
    helper expect "$PID" opus
    capture_window "$(localized Translation)" "provider-incompatible-effort$2"
    CAPTURE_UNKNOWN_EFFORT=1 launch 1 "" anthropic
    open_menu
    ax "click menu item \"$(localized "Settings…")\" of menu 1 of $STATUS_ITEM" >/dev/null
    sleep 1
    helper expect-enabled "$PID" translation-effort
    helper expect "$PID" "$(localized "The CLI catalog does not report effort support for this model.")"
    capture_window "$(localized Translation)" "provider-unknown-effort$2"
    if ! helper reset-picker "$PID" translation-effort "$(localized Default)"; then
        capture_window "$(localized Translation)" "provider-reset-failed$2"
        return 1
    fi
    capture_window "$(localized Translation)" "provider-unknown-effort-default$2"
}

capture_all() {
    if [ "${CAPTURE_PROVIDERS_ONLY:-0}" = 1 ]; then capture_providers "$1" "$2"; return; fi
    if [ "${CAPTURE_ACTIVITY_ONLY:-0}" = 1 ]; then capture_activity "$1" "$2"; return; fi
    if [ "${CAPTURE_MODELS_ONLY:-0}" = 1 ]; then capture_models "$1" "$2"; return; fi
    if [ "${CAPTURE_ONBOARDING_ONLY:-0}" = 1 ]; then capture_onboarding "$1" "$2"; return; fi
    if [ "${CAPTURE_RESULTS_ONLY:-0}" = 1 ]; then capture_results "$1" "$2"; return; fi
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
    if [ "${CAPTURE_MENU_ONLY:-0}" = 1 ]; then close_menu; return; fi
    capture_settings "$(localized General)" "general$2"

    launch 1
    open_menu
    capture_settings "$(localized Translation)" "settings$2"

    launch 1 "" local
    open_menu
    capture_settings "$(localized Translation)" "settings-local$2"

    launch 2
    open_menu
    capture_settings "$(localized Rewrite)" "rewrite$2"

    launch 3 settings
    open_menu
    capture_settings "$(localized Dictation)" "dictation$2"

    capture_activity "$1" "$2"
}

case "${CAPTURE_APPEARANCE:-both}" in
    light) capture_all false "" ;;
    dark) capture_all true -dark ;;
    both) capture_all false ""; capture_all true -dark ;;
    current)
        CURRENT_DARK=$(appearance 'get dark mode')
        if [ "$CURRENT_DARK" = true ]; then capture_all true -dark; else capture_all false ""; fi ;;
    *) echo "CAPTURE_APPEARANCE must be light, dark, both, or current." >&2; exit 2 ;;
esac

