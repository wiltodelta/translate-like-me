import CryptoKit
import Foundation
import Network
import os

private let log = Logger.app("models")

// Validate the app-owned Hub snapshot before both offline use and resuming a
// download. The SDK trusts matching commit metadata without rehashing the file.
// Dictation and local translation models share it.
struct ModelSnapshot: Sendable {
    // The files are missing and may not be fetched, or a fetch left them
    // incomplete or failing their hashes.
    struct Incomplete: Error {}

    let root: URL
    let revision: String
    let variant: String
    let required: [String]
    var pause: @Sendable (Int) async throws -> Void = ModelSnapshot.waitForNetwork

    private var folder: URL { root.appendingPathComponent(variant) }

    func prepare(download: Bool, fetch: @Sendable () async throws -> Void) async throws -> URL {
        let invalid = try invalidFiles()
        if complete && invalid.isEmpty { return root }
        guard download else { throw Incomplete() }
        // Preserve good partial downloads, but remove damaged files before the
        // SDK's metadata-only fast path can accept them again.
        for file in invalid { try FileManager.default.removeItem(at: file) }
        try await Self.resuming(root, pause: pause, fetch)
        guard complete, try invalidFiles().isEmpty else { throw Incomplete() }
        return root
    }

    // The SDK gives up on a dropped connection after five one-second retries,
    // so a Wi-Fi change or sleep failed a multi-gigabyte download. It keeps each
    // partial file as .incomplete and resumes it with a Range request, and a
    // finished file costs one HEAD request, so fetching again continues where
    // the transfer stopped. Give up after attempts that add no bytes under root.
    static let attemptsWithoutProgress = 5

    static func resuming(_ root: URL, pause: @Sendable (Int) async throws -> Void = waitForNetwork,
                         _ fetch: @Sendable () async throws -> Void) async throws {
        var stalled = 0
        var before = bytesOnDisk(root)
        while true {
            try Task.checkCancellation()
            do {
                return try await fetch()
            } catch let error as URLError where isTransient(error) {
                let after = bytesOnDisk(root)
                stalled = after > before ? 0 : stalled + 1
                before = after
                guard stalled < attemptsWithoutProgress else { throw error }
                log.warning("""
                    Model download from \(root.lastPathComponent, privacy: .public) interrupted \
                    (\(error.code.rawValue)), resuming after attempt \(stalled) without progress
                    """)
                try await pause(stalled)
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        ![.cancelled, .badURL, .unsupportedURL, .userCancelledAuthentication,
          .userAuthenticationRequired, .cannotCreateFile, .cannotWriteToFile].contains(error.code)
    }

    // Counts the Hub's partial files too, which live under .cache.
    private static func bytesOnDisk(_ root: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return files.reduce(0) { total, file in
            let size = (file as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            return total + Int64(size ?? 0)
        }
    }

    // Waits for a network path, then backs off: 1 second after an attempt that
    // added bytes, else 2, 4, 8, 16.
    static let waitForNetwork: @Sendable (Int) async throws -> Void = { stalled in
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let paths = AsyncStream { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "ModelSnapshot.network"))
        }
        for await connected in paths where connected { break }
        try await Task.sleep(for: .seconds(1 << stalled))
    }

    private var complete: Bool {
        required.allSatisfy { part in
            let file = folder.appendingPathComponent(part)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }

    private func invalidFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let paths = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
            .filter { !variant.isEmpty || !$0.hasPrefix(".cache/") }
        var invalid: [URL] = []
        for path in paths {
            try Task.checkCancellation()
            let file = folder.appendingPathComponent(path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relative = variant.isEmpty ? path : variant + "/" + path
            if try !valid(file, relative: relative, size: values.fileSize ?? 0) { invalid.append(file) }
        }
        return invalid
    }

    private func valid(_ file: URL, relative: String, size: Int) throws -> Bool {
        let metadata = root.appendingPathComponent(".cache/huggingface/download/" + relative + ".metadata")
        guard size > 0, let contents = try? String(contentsOf: metadata, encoding: .utf8) else { return false }
        let fields = contents.components(separatedBy: .newlines)
        guard fields.count >= 3, fields[0] == revision, Double(fields[2]) != nil else { return false }
        let expected = fields[1]
        switch expected.count {
        case 64: return try digest(file, using: SHA256.self) == expected
        case 40:
            // Hugging Face uses a Git blob id, not a raw SHA-1, for non-LFS files.
            return try digest(file, using: Insecure.SHA1.self, prefix: Data("blob \(size)\0".utf8)) == expected
        default: return false
        }
    }

    private func digest<Hash: HashFunction>(_ file: URL, using: Hash.Type, prefix: Data = Data()) throws -> String {
        var hash = Hash()
        hash.update(data: prefix)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
