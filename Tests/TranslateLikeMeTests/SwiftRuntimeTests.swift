import Foundation
import XCTest

final class SwiftRuntimeTests: XCTestCase {
    func testMissingRuntimeIsRejected() throws {
        XCTAssertNotEqual(try checkRuntime(present: false, signed: true), 0)
    }

    func testUnsignedRuntimeIsRejected() throws {
        XCTAssertNotEqual(try checkRuntime(present: true, signed: false), 0)
    }

    func testPackagedSignedRuntimeIsAccepted() throws {
        XCTAssertEqual(try checkRuntime(present: true, signed: true), 0)
    }

    private func checkRuntime(present: Bool, signed: Bool) throws -> Int32 {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("swift-runtime-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        let app = root.appendingPathComponent("Synthetic App.app")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        for directory in [tools, frameworks, app.appendingPathComponent("Contents/MacOS")] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if present {
            try Data("synthetic runtime".utf8)
                .write(to: frameworks.appendingPathComponent("libswiftCompatibilitySpan.dylib"))
        }
        // Only external tools are replaced; the production bundle guard runs unchanged.
        let commands = ["xcrun": "#!/bin/sh\necho /toolchain/libswiftCompatibilitySpan.dylib\n",
                        "codesign": "#!/bin/sh\nexit \(signed ? 0 : 1)\n"]
        for (name, source) in commands {
            let executable = tools.appendingPathComponent(name)
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [project.appendingPathComponent("scripts/check-swift-runtime.sh").path, app.path]
        process.environment = ["PATH": "\(tools.path):/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
