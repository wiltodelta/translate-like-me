import Foundation
@preconcurrency import WhisperKit

// The downloaded translation models, private to this bundle id like the
// dictation models. A download is verified once, against the pinned revision's
// Hub hashes (ModelSnapshot), and leaves a marker; a launch then checks only the
// marker and each file's exact size, since hashing 6.7 GB would take seconds.
struct LocalModelFiles: Sendable {
    let base: URL
    let availableStorage: @Sendable (URL) throws -> Int64

    static let live = LocalModelFiles(
        base: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wiltodelta.translatelikeme.dev")
            .appendingPathComponent("Translation", isDirectory: true),
        availableStorage: { url in
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
                throw CocoaError(.fileReadUnknown)
            }
            return bytes
        })

    // Downloads leave this much free beside the model, for the system and the
    // apps being translated from.
    static let storageMargin: Int64 = 2_000_000_000

    private func source(_ model: LocalModel) -> ModelDownloadConfig {
        ModelDownloadConfig(modelRepo: model.repository, revision: model.revision)
    }

    func root(for model: LocalModel) -> URL {
        ModelDownloader(config: source(model)).localRepoLocation(downloadBase: base)
    }

    // Outside the snapshot, which ModelSnapshot treats as model files only.
    private func marker(for model: LocalModel) -> URL {
        base.appendingPathComponent("\(model.rawValue).verified")
    }

    func isInstalled(_ model: LocalModel) -> Bool {
        guard (try? String(contentsOf: marker(for: model), encoding: .utf8)) == model.revision else { return false }
        let root = root(for: model)
        return model.files.allSatisfy { has($0, in: root) }
    }

    // Bytes still to fetch: a resumed download keeps what is already there.
    func remainingBytes(_ model: LocalModel) -> Int64 {
        let root = root(for: model)
        return model.files.reduce(0) { $0 + (has($1, in: root) ? 0 : $1.bytes) }
    }

    private func has(_ file: (name: String, bytes: Int64), in root: URL) -> Bool {
        let values = try? root.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init) == file.bytes
    }

    // One file at a time, so progress follows bytes: the Hub client weighs each
    // file equally, and one TranslateGemma file is 5.4 of its 6.7 GB.
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let needed = remainingBytes(model)
        guard try availableStorage(base) >= needed + Self.storageMargin else {
            throw LocalModelError.insufficientStorage(needed + Self.storageMargin)
        }
        try? FileManager.default.removeItem(at: marker(for: model))
        let root = root(for: model)
        let snapshot = ModelSnapshot(root: root, revision: model.revision, variant: "",
                                     required: model.files.map(\.name))
        let source = source(model)
        do {
            _ = try await snapshot.prepare(download: true) {
                let hub = HubApiWrapper(downloadBase: base, endpoint: source.endpoint)
                let total = Double(model.downloadBytes)
                var done: Int64 = 0
                // ModelSnapshot removed every file failing its hash, so one
                // of the full size is good and needs no Hub request.
                for file in model.files {
                    defer {
                        done += file.bytes
                        progress(Double(done) / total)
                    }
                    if has(file, in: root) { continue }
                    let before = Double(done)
                    _ = try await hub.snapshot(from: .init(id: source.modelRepo), revision: source.revision,
                                               matching: [file.name]) {
                        progress((before + $0.fractionCompleted * Double(file.bytes)) / total)
                    }
                }
            }
        } catch is ModelSnapshot.Incomplete {
            throw LocalModelError.incomplete
        }
        try model.revision.write(to: marker(for: model), atomically: true, encoding: .utf8)
    }

    func remove(_ model: LocalModel) throws {
        try? FileManager.default.removeItem(at: marker(for: model))
        let root = root(for: model)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

enum LocalModelError: LocalizedError {
    case notDownloaded(LocalModel)
    case insufficientMemory(LocalModel)
    case insufficientStorage(Int64)
    case incomplete

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let model):
            String(localized: "\(model.title) is not downloaded yet. Download it in Settings > Translation.",
                   comment: "The placeholder is a model name, such as TranslateGemma 12B")
        case .insufficientMemory(let model):
            String(localized: """
                \(model.title) needs a Mac with at least \(Int(model.minimumMemory >> 30)) GB of memory. \
                Choose a smaller model in Settings > Translation.
                """, comment: "The first placeholder is a model name, the second a number of gigabytes")
        case .insufficientStorage(let bytes):
            String(localized: "Free at least \(Self.gigabytes(bytes)) of disk space, then download again.",
                   comment: "The placeholder is an amount of disk space, such as 8.7 GB")
        case .incomplete:
            String(localized: "The download was incomplete or damaged. Download it again.")
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
