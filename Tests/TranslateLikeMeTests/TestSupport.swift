import Foundation
import os
import XCTest
@testable import TranslateLikeMe

extension XCTestCase {
    // Points `variable` (CODEX_HOME, GROK_HOME, CLAUDE_CONFIG_DIR) at a throwaway
    // directory holding `file`, so a test never reads the real machine's CLI files.
    func withConfigDir(_ variable: String, file: String, contents: String?, _ body: () throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-\(UUID().uuidString)")
        let url = dir.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents { try? contents.write(to: url, atomically: true, encoding: .utf8) }
        setenv(variable, dir.path, 1)
        defer {
            unsetenv(variable)
            try? FileManager.default.removeItem(at: dir)
        }
        try body()
    }
}

// A pasteboard, focus and destination app in memory, for translation and
// dictation alike. The destination reads the clipboard once `readDelay` has
// passed on the injected clock; without one it never reads.
struct FakePasteAccess: SelectionAccess {
    struct State {
        var destination: pid_t? = 41
        var clipboard = "original clipboard"
        var count = 0
        var selection = "selection"
        var copies = 0
        var pastes: [(text: String, pid: pid_t)] = []
        var receipt: PasteReceipt?
        var readDelay: Duration?
        var clipboardAtRead: String?
        var copyDuringSnapshot = false
        var elapsed: Duration = .zero
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var changeCount: Int { state.withLock { $0.count } }
    func snapshot() -> String {
        let snapshot = state.withLock { $0.clipboard }
        if state.withLock({ $0.copyDuringSnapshot }) { userCopy() }
        return snapshot
    }
    func restore(_ snapshot: String, ifUnchangedSince mark: Int) {
        state.withLock { if $0.count == mark { $0.clipboard = snapshot; $0.count += 1 } }
    }
    func userCopy(_ text: String = "new copy") { state.withLock { $0.clipboard = text; $0.count += 1 } }
    func advance(_ duration: Duration) {
        state.withLock {
            $0.elapsed += duration
            guard let delay = $0.readDelay, let receipt = $0.receipt, !receipt.wasRead,
                  $0.elapsed >= delay else { return }
            receipt.recordRead()
            $0.clipboardAtRead = $0.clipboard
        }
    }
    func destination() -> pid_t? { state.withLock { $0.destination } }
    func copySelection() -> CopiedSelection {
        state.withLock {
            $0.copies += 1
            $0.clipboard = $0.selection
            $0.count += 1
            return CopiedSelection(text: $0.selection, changeCount: $0.count)
        }
    }
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> PromisedPaste? {
        state.withLock {
            guard $0.count == mark else { return nil }
            let receipt = PasteReceipt(text: text)
            $0.clipboard = text
            $0.count += 1
            $0.pastes.append((text, pid))
            $0.receipt = receipt
            return PromisedPaste(changeCount: $0.count, receipt: receipt)
        }
    }
}
