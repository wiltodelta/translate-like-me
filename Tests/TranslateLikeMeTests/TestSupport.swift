import Foundation
import XCTest

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
