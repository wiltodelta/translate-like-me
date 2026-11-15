#!/usr/bin/env python3
"""Run end-to-end synthetic dictation verification across AX, PasteDelivery, and both ASR models."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import logging
import math
import os
from pathlib import Path
import random
import signal
import tempfile
import textwrap

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
CHECK_TIMEOUT = 900


def helper(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUDIO = helper("check-dictation-audio")
RATE = AUDIO.RATE

AX_HELPER_SWIFT = textwrap.dedent(
    """\
    import AppKit
    import Darwin
    import Foundation

    final class SlowAXView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
        override func accessibilitySubrole() -> NSAccessibility.Subrole? {
            Thread.sleep(forTimeInterval: 1.2)
            return nil
        }
    }

    final class UnboundedNoCountAXView: NSView {
        var valueReads = 0
        private let payload = String(repeating: "z", count: 50_000)

        override var acceptsFirstResponder: Bool { true }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
        override func accessibilityValue() -> Any? {
            valueReads += 1
            return payload
        }
    }

    final class OffscreenAXApp: NSApplication {
        weak var targetWindow: NSWindow?

        override func accessibilityFocusedWindow() -> Any? {
            targetWindow
        }

        override func accessibilityMainWindow() -> Any? {
            targetWindow
        }

        override func accessibilityWindows() -> [Any]? {
            targetWindow.map { [$0] } ?? []
        }

        override func accessibilityApplicationFocusedUIElement() -> Any? {
            guard let responder = targetWindow?.firstResponder else { return nil }
            if let tv = responder as? NSTextView, tv.isFieldEditor,
               let control = tv.delegate as? NSControl, let cell = control.cell {
                return cell
            }
            return NSAccessibility.unignoredAncestor(of: responder)
        }
    }

    @MainActor
    final class HarnessController {
        private let board: NSPasteboard
        private let window: NSWindow
        private var textView: NSTextView?
        private var textField: NSTextField?
        private var noCountView: UnboundedNoCountAXView?

        init(boardName: String, app: OffscreenAXApp) {
            board = NSPasteboard(name: NSPasteboard.Name(boardName))
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.orderBack(nil)
            app.targetWindow = window
        }

        func handle(_ line: String) {
            if line == "QUIT" {
                exit(0)
            }
            if line == "PASTE" {
                paste()
                return
            }
            if line == "GET" {
                let encoded = Data(readText().utf8).base64EncodedString()
                reply("VAL \\(encoded)")
                return
            }
            if line.hasPrefix("SET ") {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4,
                      let titleData = Data(base64Encoded: String(parts[2])),
                      let title = String(data: titleData, encoding: .utf8),
                      let textData = Data(base64Encoded: String(parts[3])),
                      let text = String(data: textData, encoding: .utf8) else {
                    reply("ERR")
                    return
                }
                configure(mode: String(parts[1]), title: title, text: text)
                reply("OK")
            }
        }

        private func configure(mode: String, title: String, text: String) {
            window.title = title
            textView = nil
            textField = nil
            noCountView = nil
            switch mode {
            case "textfield", "secure":
                let rect = NSRect(x: 0, y: 0, width: 560, height: 32)
                let field = mode == "secure" ? NSSecureTextField(frame: rect) : NSTextField(frame: rect)
                field.isEditable = true
                field.isSelectable = true
                field.stringValue = text
                window.contentView = field
                _ = window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
                }
                textField = field
            case "large":
                let full = String(repeating: "x", count: 40_000) + text
                installTextView(full, caretOffset: full.utf16.count)
            case "near_end":
                installTextView(text, caretOffset: max(0, text.utf16.count - 5))
            case "slow":
                let slow = SlowAXView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
                window.contentView = slow
                _ = window.makeFirstResponder(slow)
            case "unbounded_no_count":
                let custom = UnboundedNoCountAXView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
                window.contentView = custom
                _ = window.makeFirstResponder(custom)
                noCountView = custom
            default:
                installTextView(text, caretOffset: text.utf16.count)
            }
        }

        private func installTextView(_ text: String, caretOffset: Int) {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
            view.isEditable = true
            view.isSelectable = true
            view.isRichText = false
            view.string = text
            window.contentView = view
            _ = window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: caretOffset, length: 0))
            textView = view
        }

        private func paste() {
            guard let pasted = board.string(forType: .string) else { return }
            if let view = textView {
                let range = view.selectedRange()
                view.replaceCharacters(in: range, with: pasted)
                view.setSelectedRange(NSRange(location: range.location + pasted.utf16.count, length: 0))
            } else if let field = textField {
                if let editor = field.currentEditor() as? NSTextView {
                    let range = editor.selectedRange
                    editor.replaceCharacters(in: range, with: pasted)
                    editor.selectedRange = NSRange(location: range.location + pasted.utf16.count, length: 0)
                    field.stringValue = editor.string
                } else {
                    field.stringValue += pasted
                }
            }
        }

        private func readText() -> String {
            if let custom = noCountView { return "VALUE_READS=\\(custom.valueReads)" }
            if let view = textView { return view.string }
            if let field = textField { return (field.currentEditor() as? NSTextView)?.string ?? field.stringValue }
            return ""
        }

        private func reply(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\\n").utf8))
        }
    }

    MainActor.assumeIsolated {
        let app = OffscreenAXApp.shared as! OffscreenAXApp
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let boardName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TranslateLikeMe.E2E"
        let controller = HarnessController(boardName: boardName, app: app)

        var incoming = Data()
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        reader.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
                if count > 0 {
                    incoming.append(contentsOf: chunk[0..<count])
                    while let newline = incoming.firstIndex(of: 0x0A) {
                        let lineData = incoming.subdata(in: 0..<newline)
                        incoming.removeSubrange(0...newline)
                        if let line = String(data: lineData, encoding: .utf8) {
                            MainActor.assumeIsolated { controller.handle(line) }
                        }
                    }
                } else if count == 0 {
                    exit(0)
                } else {
                    break
                }
            }
        }
        DispatchQueue.main.async {
            reader.resume()
            FileHandle.standardOutput.write(Data("READY \\(getpid())\\n".utf8))
        }
        app.run()
    }
    """
)


def room_floor(duration_seconds, amplitude=65):
    count = round(RATE * duration_seconds)
    return [round(amplitude * math.sin(2.0 * math.pi * 190.0 * index / RATE)) for index in range(count)]


def mix_floor(samples, amplitude=960):
    return [
        max(-32768, min(32767, sample + round(amplitude * math.sin(2.0 * math.pi * 190.0 * index / RATE))))
        for index, sample in enumerate(samples)
    ]


def scale_to_peak(samples, peak_fraction):
    peak = max((abs(value) for value in samples), default=1) or 1
    target = peak_fraction * 32767.0
    return [max(-32768, min(32767, round(value * target / peak))) for value in samples]


def trim_outer(samples, threshold=80):
    start = 0
    while start < len(samples) and abs(samples[start]) < threshold:
        start += 1
    end = len(samples)
    while end > start and abs(samples[end - 1]) < threshold:
        end -= 1
    return list(samples[start:end]) if end > start else list(samples)


def synthesize(folder, stem, voice, text, rate=175):
    aiff = folder / (stem + ".aiff")
    raw_wav = folder / (stem + "-raw.wav")
    AUDIO.run(["/usr/bin/say", "-v", voice, "-r", str(rate), "-o", aiff, text], timeout=45)
    AUDIO.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1", aiff, raw_wav], timeout=45)
    samples = trim_outer(AUDIO.read_pcm(raw_wav))
    aiff.unlink(missing_ok=True)
    raw_wav.unlink(missing_ok=True)
    return samples


def build_helper(folder):
    source = folder / "OffscreenAXHelper.swift"
    binary = folder / "ax-helper"
    source.write_text(AX_HELPER_SWIFT)
    AUDIO.run(["/usr/bin/swiftc", "-O", source, "-o", binary], timeout=120)
    source.unlink(missing_ok=True)


def write_noise_fixtures(folder):
    rng = random.Random(20261114)
    count = round(RATE * 2.5)
    white = [rng.uniform(-1.0, 1.0) for _ in range(count)]
    AUDIO.write_pcm(folder / "noise_white_006.wav", scale_to_peak(white, 0.006))

    pink = []
    acc = 0.0
    for sample in white:
        acc = 0.94 * acc + 0.06 * sample
        pink.append(acc)
    AUDIO.write_pcm(folder / "noise_pink_035.wav", scale_to_peak(pink, 0.035))

    clicks = [round(rng.uniform(-1.0, 1.0) * 0.001 * 32767.0) for _ in range(count)]
    click_len = round(RATE * 0.002)
    for offset_sec in (0.4, 0.95, 1.5, 2.05):
        base = round(RATE * offset_sec)
        for index in range(click_len):
            sign = 1 if index % 2 == 0 else -1
            clicks[base + index] = round(sign * 0.090 * 32767.0)
    AUDIO.write_pcm(folder / "noise_clicks_090.wav", clicks)


def prepare_workspace(folder):
    ru_voice = "Milena (Russian (Russia))"
    de_voice = "Anna (German (Germany))"
    ja_voice = "Kyoko (Japanese (Japan))"

    jobs = {
        "commit_ru": (ru_voice, "Коммит и пуш", 175),
        "sessiya": (ru_voice, "Сессия", 175),
        "prodolzhay_fast": (ru_voice, "Продолжай", 235),
        "prodolzhay": (ru_voice, "Продолжай", 175),
        "privet": (ru_voice, "Привет, я буду через десять минут.", 175),
        "commit_de": (de_voice, "Commit und Push", 175),
        "sessiya_ja": (ja_voice, "セッションを開始します", 175),
    }

    with ThreadPoolExecutor(max_workers=4) as pool:
        helper_future = pool.submit(build_helper, folder)
        tts_futures = {
            key: pool.submit(synthesize, folder, key, voice, text, rate)
            for key, (voice, text, rate) in jobs.items()
        }
        helper_future.result()
        clips = {key: future.result() for key, future in tts_futures.items()}

    AUDIO.write_pcm(folder / "commit_push_ru.wav", room_floor(0.15) + clips["commit_ru"] + room_floor(0.45))

    # Two-word phrase over a -33 dBFS floor through "Продолжай", with Option released at a
    # 360 ms -33 dBFS bridge before "Продолжай" and a -57 dBFS quiet room tail afterwards:
    # exercises `releaseTail`, `maximumFloor = 0.35` (mutating `maximumFloor` to 1.0 reaches
    # 300 ms quiet at the bridge and clips "Продолжай"), and early tail cutoff before file end.
    breath_bridge = room_floor(0.36, amplitude=960)
    quiet_tail = room_floor(0.65, amplitude=65)
    tail_clip = (
        room_floor(0.06, amplitude=960)
        + mix_floor(clips["sessiya"], amplitude=960)
        + breath_bridge
        + mix_floor(clips["prodolzhay_fast"], amplitude=960)
        + quiet_tail
    )
    tail_chunks = (len(breath_bridge) + len(clips["prodolzhay_fast"]) + len(quiet_tail)) // 2400
    (folder / "tail_chunks.txt").write_text(str(tail_chunks))
    AUDIO.write_pcm(folder / "prodolzhay_tail.wav", tail_clip)

    quiet_sessiya = scale_to_peak(clips["sessiya"], 0.010)
    AUDIO.write_pcm(folder / "sessiya_quiet010.wav", [0] * (RATE // 5) + quiet_sessiya + [0] * (RATE // 3))
    AUDIO.write_pcm(
        folder / "soft_lead_pause_ru.wav",
        [0] * round(RATE * 1.5)
        + scale_to_peak(clips["sessiya"], 0.040)
        + [0] * round(RATE * 0.80)
        + clips["prodolzhay"]
        + [0] * round(RATE * 1.5),
    )
    AUDIO.write_pcm(folder / "privet_ru.wav", room_floor(0.15) + clips["privet"] + room_floor(0.40))
    AUDIO.write_pcm(folder / "commit_push_de.wav", room_floor(0.15) + clips["commit_de"] + room_floor(0.40))
    AUDIO.write_pcm(folder / "sessiya_ja.wav", room_floor(0.15) + clips["sessiya_ja"] + room_floor(0.40))
    AUDIO.write_pcm(folder / "prodolzhay_padded.wav", [0] * (RATE * 2) + clips["prodolzhay"] + [0] * (RATE * 2))
    write_noise_fixtures(folder)


def validate_xctest_output(output):
    if "Executed 1 test, with 0 failures" not in output or "1 test skipped" in output:
        raise RuntimeError("Expected 1 executed E2E test with 0 skips, got:\n%s" % output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Reuse an already built test bundle")
    parser.add_argument("--report", type=Path, default=ROOT / ".build/dictation-e2e-check/report.json")
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "failed",
        "microphoneUsed": False,
        "speakersUsed": False,
        "desktopFocusStolen": False,
        "generalPasteboardTouched": False,
        "scope": (
            "DictationController, streaming 48 kHz WAV sink, post-release tail, "
            "cross-process AppKit AXUIElement snapshots and child-element timeouts "
            "(NSTextView, NSTextField, NSSecureTextField, >32k buffer, stalled child, "
            "unknown count), promised NSPasteboard delivery, Qwen3-ASR contextual/quiet/"
            "multilingual/boundary/noise-echo decoding, and Whisper Turbo"
        ),
    }
    args.report.write_text(json.dumps(dict(report, status="running"), indent=2) + "\n")
    folder = None
    try:
        with tempfile.TemporaryDirectory(prefix="tlm-synthetic-e2e-") as temporary:
            folder = Path(temporary)
            log.info("Preparing offscreen AppKit AX helper and 48 kHz synthetic speech/noise fixtures")
            prepare_workspace(folder)
            environment = dict(os.environ, TLM_E2E_SYNTHETIC_CHECK=str(folder))
            command = ["swift", "test"]
            if args.skip_build:
                command.append("--skip-build")
            command += [
                "--filter",
                "DictationEndToEndSyntheticTests/testFullControllerAXPasteboardAndModelsWithSyntheticSpeech",
            ]
            log.info("Running end-to-end synthetic check, subprocess deadline %s seconds", CHECK_TIMEOUT)
            output = AUDIO.run(command, env=environment, timeout=CHECK_TIMEOUT)
            args.report.with_suffix(".log").write_text(output)
            validate_xctest_output(output)
            report["status"] = "passed"
            log.info("End-to-end synthetic check passed")
    except Exception as error:
        log.error("%s", error)
        report["reason"] = str(error)
    finally:
        report["temporaryDirectoryRemoved"] = folder is None or not folder.exists()
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    raise SystemExit(main())
