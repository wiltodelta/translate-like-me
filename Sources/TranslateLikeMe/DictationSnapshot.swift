import CryptoKit
import Foundation

// Validate the app-owned Hub snapshot before both offline use and resuming a
// download. The SDK trusts matching commit metadata without rehashing the file.
struct DictationSnapshot: Sendable {
    let root: URL
    let revision: String
    let variant: String
    let required: [String]

    private var folder: URL { root.appendingPathComponent(variant) }

    func prepare(download: Bool, fetch: @Sendable () async throws -> Void) async throws -> URL {
        let invalid = try invalidFiles()
        if complete && invalid.isEmpty { return root }
        guard download else { throw DictationError.notReady }
        // Preserve good partial downloads, but remove damaged files before the
        // SDK's metadata-only fast path can accept them again.
        for file in invalid { try FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        try await fetch()
        guard complete, try invalidFiles().isEmpty else { throw DictationError.notReady }
        return root
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
