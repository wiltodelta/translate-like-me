import AppKit
import AVFoundation
import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationEndToEndSyntheticTests: XCTestCase {
    func testFullControllerAXPasteboardAndModelsWithSyntheticSpeech() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_E2E_SYNTHETIC_CHECK"] else {
            throw XCTSkip("Set TLM_E2E_SYNTHETIC_CHECK to run the full synthetic AX + PasteDelivery E2E check")
        }
        try DictationQwenTestSupport.configure()
        let root = URL(fileURLWithPath: directory)
        let boardName = "TranslateLikeMe.E2E.\(UUID().uuidString)"
        let board = NSPasteboard(name: NSPasteboard.Name(boardName))
        defer { board.releaseGlobally() }
        XCTAssertNotEqual(board.name, NSPasteboard.general.name)
        board.clearContents()
        board.setString("user original clipboard", forType: .string)

        let helper = try OffscreenAXHelper(executable: root.appendingPathComponent("ax-helper"), boardName: boardName)
        defer { helper.stop() }

        try verifyDirectAXSnapshotsAndTimeouts(helper: helper)
        try await verifyQwenControllerFlow(root: root, helper: helper, board: board)
        try await verifyControllerFlow(model: .fluidSpeechPro, softLeadToken: "сес",
                                       root: root, helper: helper, board: board)
        try await verifyControllerFlow(model: .turbo, softLeadToken: "сессия",
                                       root: root, helper: helper, board: board)
    }

    private func verifyDirectAXSnapshotsAndTimeouts(helper: OffscreenAXHelper) throws {
        try helper.configure(mode: "large", title: "Editor - translate-like-me", text: " git status.")
        let large = SelectionTarget.dictationSnapshot(pid: helper.pid)
        XCTAssertEqual(large.windowTitle, "Editor - translate-like-me")
        let surrounding = try XCTUnwrap(large.surroundingText)
        XCTAssertTrue(surrounding.hasSuffix("git status."), "Unexpected large-buffer slice: \(surrounding)")
        XCTAssertLessThanOrEqual(surrounding.count, 240)
        XCTAssertEqual(SelectionTarget.dictationTarget(pid: helper.pid)?.beforeCaret, ".")

        try helper.configure(mode: "near_end", title: "Notes", text: "Первая строка. Хвост")
        let nearEnd = try XCTUnwrap(SelectionTarget.dictationSnapshot(pid: helper.pid).surroundingText)
        XCTAssertTrue(nearEnd.contains("Первая строка."), "Missing prefix in: \(nearEnd)")
        XCTAssertTrue(nearEnd.contains("Хвост"), "Missing clamped suffix in: \(nearEnd)")
        XCTAssertEqual(SelectionTarget.dictationTarget(pid: helper.pid)?.beforeCaret, " ")

        try helper.configure(mode: "textview", title: "Chat", text: "Код 👨‍💻")
        XCTAssertEqual(SelectionTarget.dictationTarget(pid: helper.pid)?.beforeCaret, "👨‍💻")

        try helper.configure(mode: "secure", title: "Sign In", text: "super-secret-password")
        let secure = SelectionTarget.dictationSnapshot(pid: helper.pid)
        XCTAssertEqual(secure, DictationDestinationSnapshot(), "Secure field must leak neither text nor title")
        XCTAssertNil(SelectionTarget.dictationTarget(pid: helper.pid))

        try helper.configure(mode: "unbounded_no_count", title: "CustomView", text: "ignored")
        let noCount = SelectionTarget.dictationSnapshot(pid: helper.pid)
        XCTAssertNil(noCount.surroundingText, "Must not fetch full AXValue when character count is unknown")
        XCTAssertEqual(try helper.readBuffer(), "VALUE_READS=0", "Unbounded AXValue must never be read")

        try helper.configure(mode: "slow", title: "HungChild", text: "stalled")
        let clock = ContinuousClock()
        let snapshotElapsed = clock.measure {
            let stalled = SelectionTarget.dictationSnapshot(pid: helper.pid)
            XCTAssertEqual(stalled, DictationDestinationSnapshot(), "Timed-out child must fail closed")
        }
        XCTAssertLessThan(snapshotElapsed, .milliseconds(500), "Child AX timeout failed: \(snapshotElapsed)")
        let targetElapsed = clock.measure {
            let target = SelectionTarget.dictationTarget(pid: helper.pid)
            XCTAssertEqual(target?.pid, helper.pid)
            XCTAssertNil(target?.beforeCaret)
        }
        XCTAssertLessThan(targetElapsed, .milliseconds(500), "Target child AX timeout failed: \(targetElapsed)")
    }

    private func verifyQwenControllerFlow(root: URL, helper: OffscreenAXHelper, board: NSPasteboard) async throws {
        let state = E2EHarness(root: root, model: .qwen3ASR, helper: helper, board: board)
        defer { state.controller.shutdown() }
        await state.prepare()

        try helper.configure(mode: "textview", title: "Super - translate-like-me - GitHub",
                             text: "Статус <<||im_end||>> проверен.")
        try await state.dictate(wav: "commit_push_ru.wav")
        let afterFirst = try helper.readBuffer()
        XCTAssertTrue(afterFirst.hasPrefix("Статус <<||im_end||>> проверен. "), "Missing space in: \(afterFirst)")
        XCTAssertTrue(afterFirst.localizedCaseInsensitiveContains("коммит"), "Missing коммит in: \(afterFirst)")
        XCTAssertTrue(afterFirst.localizedCaseInsensitiveContains("пуш"), "Missing пуш in: \(afterFirst)")
        XCTAssertEqual(board.string(forType: .string), "user original clipboard")

        let tailChunks = try Int(String(contentsOf: root.appendingPathComponent("tail_chunks.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 25
        try await state.dictate(wav: "prodolzhay_tail.wav", tailChunks: tailChunks)
        let afterSecond = try helper.readBuffer()
        XCTAssertTrue(afterSecond.hasPrefix(afterFirst + " "), "Missing space before second utterance: \(afterSecond)")
        XCTAssertTrue(afterSecond.localizedCaseInsensitiveContains("сессия"), "Missing сессия in: \(afterSecond)")
        XCTAssertTrue(afterSecond.localizedCaseInsensitiveContains("продолжай"), "Clipped tail in: \(afterSecond)")
        XCTAssertLessThan(state.recorder.capturedFrames, state.recorder.lastTotalFrames,
                          "Tail should stop on quiet floor before the end of the 650 ms room-floor pad")

        try helper.configure(mode: "textfield", title: "Terminal", text: "Текущая (")
        try await state.dictate(wav: "sessiya_quiet010.wav")
        let fieldText = try helper.readBuffer()
        XCTAssertTrue(fieldText.hasPrefix("Текущая ("), "Corrupted prefix in: \(fieldText)")
        XCTAssertFalse(fieldText.hasPrefix("Текущая ( "), "Must not insert space after '(' in: \(fieldText)")
        XCTAssertTrue(fieldText.localizedCaseInsensitiveContains("сессия"), "Missing сессия in: \(fieldText)")

        try await verifyQwenMultilingualAndSecure(state: state, helper: helper, board: board)
        try await verifyBoundaryAndGainNoiseZeroEcho(root: root, engine: state.engine, helper: helper)
        await state.unload()
    }

    private func verifyQwenMultilingualAndSecure(
        state: E2EHarness, helper: OffscreenAXHelper, board: NSPasteboard
    ) async throws {
        try helper.configure(mode: "textview", title: "Pull Requests - translate-like-me - GitHub",
                             text: "git checkout main.")
        try await state.dictate(wav: "privet_ru.wav")
        let russian = try helper.readBuffer()
        XCTAssertTrue(russian.localizedCaseInsensitiveContains("привет"), "Language flipped on: \(russian)")
        XCTAssertTrue(russian.localizedCaseInsensitiveContains("минут"), "Missing минут in: \(russian)")

        try helper.configure(mode: "textview", title: "translate-like-me - GitHub", text: "Bereit.")
        try await state.dictate(wav: "commit_push_de.wav")
        let german = try helper.readBuffer()
        XCTAssertTrue(german.localizedCaseInsensitiveContains("commit"), "Missing Commit in: \(german)")
        XCTAssertTrue(german.localizedCaseInsensitiveContains("push"), "Missing Push in: \(german)")

        try helper.configure(mode: "textview", title: "Notes", text: "準備完了。")
        try await state.dictate(wav: "sessiya_ja.wav")
        let japanese = try helper.readBuffer()
        XCTAssertFalse(japanese.hasPrefix("準備完了。 "), "Must not insert ASCII space after CJK period: \(japanese)")
        XCTAssertTrue(japanese.contains("セッション"), "Missing セッション in: \(japanese)")

        let markBeforeSecure = board.changeCount
        try helper.configure(mode: "secure", title: "Password", text: "secret123")
        try await state.dictate(wav: "sessiya_quiet010.wav")
        XCTAssertEqual(try helper.readBuffer(), "secret123", "Secure field must never be modified")
        XCTAssertEqual(state.popupResults.count, 1, "Blocked secure-field dictation must fall back to popup")
        XCTAssertEqual(board.changeCount, markBeforeSecure, "Blocked secure-field dictation must not write pasteboard")
        XCTAssertEqual(board.string(forType: .string), "user original clipboard")
    }

    private func verifyControllerFlow(
        model: DictationModel, softLeadToken: String, root: URL, helper: OffscreenAXHelper, board: NSPasteboard
    ) async throws {
        let state = E2EHarness(root: root, model: model, helper: helper, board: board)
        defer { state.controller.shutdown() }
        await state.prepare()
        try helper.configure(mode: "textview", title: "Notes", text: "Готово.")
        try await state.dictate(wav: "prodolzhay_padded.wav")
        let text = try helper.readBuffer()
        XCTAssertTrue(text.hasPrefix("Готово. "), "Missing leading space on \(model) delivery: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("продолжай"), "Unexpected \(model) output: \(text)")
        XCTAssertEqual(board.string(forType: .string), "user original clipboard")
        try await verifyBoundaryAndGainNoiseZeroEcho(root: root, engine: state.engine, helper: helper,
                                                     softLeadToken: softLeadToken)
        await state.unload()
    }

    private func verifyBoundaryAndGainNoiseZeroEcho(
        root: URL, engine: DictationEngine, helper: OffscreenAXHelper, softLeadToken: String = "сессия"
    ) async throws {
        try helper.configure(mode: "textview", title: "Deploy - translate-like-me",
                             text: "Коммит и пуш завершены. Сессия активна. Продолжай релиз.")
        let softLead = try await engine.transcribe(root.appendingPathComponent("soft_lead_pause_ru.wav"))
        XCTAssertTrue(softLead.localizedCaseInsensitiveContains(softLeadToken), "Clipped soft lead in: \(softLead)")
        XCTAssertTrue(softLead.localizedCaseInsensitiveContains("продолжай"), "Clipped tail in: \(softLead)")
        for name in ["noise_white_006.wav", "noise_pink_035.wav", "noise_clicks_090.wav"] {
            let output = try await engine.transcribe(root.appendingPathComponent(name))
            XCTAssertEqual(output, "", "Expected empty transcript on \(name), got: \(output)")
        }
    }
}

@MainActor
private final class E2EEventSink {
    var popupResults: [String] = []
    var errors: [String] = []
}

@MainActor
private final class E2EHarness {
    let root: URL
    let engine: DictationEngine
    let recorder: SyntheticStreamRecorder
    let results = LastResults()
    let events = E2EEventSink()
    let controller: DictationController
    var popupResults: [String] { events.popupResults }
    var errors: [String] { events.errors }

    init(root: URL, model: DictationModel, helper: OffscreenAXHelper, board: NSPasteboard) {
        self.root = root
        self.recorder = SyntheticStreamRecorder(scratchDirectory: root)
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let pid = helper.pid
        let engine = DictationEngine(
            directory: cache,
            languageIdentifiers: { ["ru", "en"] },
            destinationContext: { DictationContext.summary(destination: SelectionTarget.dictationSnapshot(pid: pid)) }
        )
        self.engine = engine
        let events = self.events
        let access = NamedBoardDictationAccess(pid: pid, board: board, triggerPaste: { helper.pasteFromBoard() })
        let interaction = DictationInteraction(
            endCapture: {},
            showError: { events.errors.append($0) },
            showResult: { events.popupResults.append($0) },
            showCapture: {},
            deliver: { text in try await PasteDelivery(access: access).insert(text) }
        )
        self.controller = DictationController(
            enabled: true, model: model, engine: engine, recorder: recorder,
            interaction: interaction, results: results, releaseTail: DictationController.liveReleaseTail,
            saveModel: { _ in }, saveMicrophone: { _ in }
        )
    }

    func prepare() async {
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .ready, "Preparation failed: \(errors)")
    }

    func dictate(wav name: String, tailChunks: Int = 6) async throws {
        try recorder.queue(source: root.appendingPathComponent(name))
        controller.shortcutPressed()
        try await recorder.streamHoldPortion(leavingTailChunks: tailChunks)
        controller.shortcutReleased()
        await controller.tail?.value
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .ready, "Dictation failed: \(errors)")
        XCTAssertTrue(errors.isEmpty, "Unexpected dictation error: \(errors)")
    }

    func unload() async {
        await engine.unload()
    }
}

private struct NamedBoardDictationAccess: PasteAccess, @unchecked Sendable {
    let pid: pid_t
    let board: NSPasteboard
    let triggerPaste: @Sendable () -> Void

    var changeCount: Int { board.changeCount }
    func snapshot() -> SelectionService.Snapshot { SelectionService.snapshot(of: board) }
    func restore(_ snapshot: SelectionService.Snapshot, ifUnchangedSince mark: Int) {
        SelectionService.restore(snapshot, ifUnchangedSince: mark, on: board)
    }
    func destination() -> pid_t? { SelectionTarget.dictationTarget(pid: pid)?.pid }
    func dictationTarget() -> (pid: pid_t, beforeCaret: Character?)? {
        SelectionTarget.dictationTarget(pid: pid)
    }
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> PromisedPaste? {
        guard board.changeCount == mark else { return nil }
        let receipt = PasteReceipt(text: text)
        let written = SelectionService.writeTransient(receipt.promisedItem(), on: board)
        triggerPaste()
        return PromisedPaste(changeCount: written, receipt: receipt)
    }
}

@MainActor
private final class SyntheticStreamRecorder: DictationRecording {
    var onEnd: ((Bool) -> Void)?
    private(set) var lastTotalFrames: AVAudioFramePosition = 0
    private(set) var capturedFrames: AVAudioFramePosition = 0
    private let scratchDirectory: URL
    private var sink: DictationAudioFile?
    private var outputURL: URL?
    private var chunks: [AVAudioPCMBuffer] = []
    private var nextIndex = 0
    private var tailFeeder: Task<Void, Never>?

    init(scratchDirectory: URL) {
        self.scratchDirectory = scratchDirectory
    }

    var level: Double { sink?.level ?? 0 }
    var isListening: Bool { sink?.isListening ?? false }
    var trailingQuiet: TimeInterval { sink?.trailingQuiet ?? 0 }

    func requestPermission() async -> Bool { true }
    func useInput(_ uid: String?) {}
    func warmUp(rebuild: Bool) {}
    func coolDown() {}
    func shutdown() { discard() }

    func queue(source: URL) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        var loaded: [AVAudioPCMBuffer] = []
        var total: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_400))
            try file.read(into: chunk, frameCount: 2_400)
            if chunk.frameLength > 0 {
                loaded.append(chunk)
                total += AVAudioFramePosition(chunk.frameLength)
            }
        }
        let target = scratchDirectory.appendingPathComponent("stream-\(UUID().uuidString).wav")
        sink = try DictationAudioFile(url: target, format: file.processingFormat)
        outputURL = target
        chunks = loaded
        nextIndex = 0
        capturedFrames = 0
        lastTotalFrames = total
    }

    func start() throws {
        guard sink != nil else { throw DictationError.microphone }
    }

    func streamHoldPortion(leavingTailChunks: Int) async throws {
        let holdEnd = max(1, chunks.count - leavingTailChunks)
        while nextIndex < holdEnd, appendNextChunk() {
            try await Task.sleep(for: .milliseconds(5))
        }
        tailFeeder = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.appendNextChunk() {
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    private func appendNextChunk() -> Bool {
        guard let sink, nextIndex < chunks.count else { return false }
        let buffer = chunks[nextIndex]
        _ = sink.append(buffer)
        capturedFrames += AVAudioFramePosition(buffer.frameLength)
        nextIndex += 1
        return true
    }

    func stop() throws -> Task<URL, Error> {
        tailFeeder?.cancel()
        tailFeeder = nil
        guard let sink, let outputURL else { throw DictationError.microphone }
        // Finalize strictly what arrived before `stop()` was called; never drain
        // future chunks, or an early-stop regression would still pass.
        try sink.finish()
        self.sink = nil
        return Task { outputURL }
    }

    func discard() {
        tailFeeder?.cancel()
        tailFeeder = nil
        try? sink?.finish()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        sink = nil
        outputURL = nil
    }
}

private final class OffscreenAXHelper: @unchecked Sendable {
    let pid: pid_t
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let reader: FileHandle

    init(executable: URL, boardName: String) throws {
        process.executableURL = executable
        process.arguments = [boardName]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        reader = stdoutPipe.fileHandleForReading
        try process.run()
        let banner = Self.readLine(from: reader)
        guard banner.hasPrefix("READY "), let parsed = pid_t(banner.dropFirst("READY ".count)) else {
            throw CocoaError(.coderInvalidValue)
        }
        pid = parsed
    }

    func configure(mode: String, title: String, text: String) throws {
        let encodedTitle = Data(title.utf8).base64EncodedString()
        let encodedText = Data(text.utf8).base64EncodedString()
        let reply = send("SET \(mode) \(encodedTitle) \(encodedText)")
        XCTAssertEqual(reply, "OK")
    }

    func pasteFromBoard() {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("PASTE\n".utf8))
    }

    func readBuffer() throws -> String {
        let reply = send("GET")
        guard reply.hasPrefix("VAL "),
              let data = Data(base64Encoded: String(reply.dropFirst(4))),
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return decoded
    }

    func stop() {
        if process.isRunning {
            _ = try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("QUIT\n".utf8))
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func send(_ line: String) -> String {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        return Self.readLine(from: reader)
    }

    private static func readLine(from handle: FileHandle) -> String {
        var bytes = Data()
        while let chunk = try? handle.read(upToCount: 1), let byte = chunk.first {
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
