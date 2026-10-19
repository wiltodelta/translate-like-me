import CryptoKit
import Foundation
@preconcurrency import WhisperKit

protocol DictationRecognizing: Sendable {
    func prepare(model: DictationModel, download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ audio: URL) async throws -> String
    func unload() async
}

// Pinned multilingual models. Model and tokenizer caches are private to this
// bundle id; no inference call needs an account or a network connection.
actor DictationEngine: DictationRecognizing {
    static let modelSource = ModelDownloadConfig(modelRepo: "argmaxinc/whisperkit-coreml",
                                                revision: "0f63a7800b00dd0226abd051b906c246e1907482")
    private let directory: URL?
    private let availableStorage: @Sendable (URL) throws -> Int64

    init(directory: URL? = nil, availableStorage: @escaping @Sendable (URL) throws -> Int64 = { url in
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return bytes.int64Value
    }) {
        self.directory = directory
        self.availableStorage = availableStorage
    }

    private var kit: WhisperKit?
    var loadedModel: DictationModel? {
        guard let folder = kit?.modelFolder?.lastPathComponent else { return nil }
        return DictationModel.allCases.first { $0.variant == folder }
    }
    private var speechDetector: DictationSpeechDetector?
    private var working = false

    func prepare(model: DictationModel = .turbo, download: Bool = true,
                 progress: @escaping @Sendable (Double) -> Void) async throws {
        guard loadedModel != model else { return }
        await unload()
        try Task.checkCancellation()
        working = true
        defer { working = false }
        let base = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wiltodelta.translatelikeme.dev")
            .appendingPathComponent("Dictation", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Core ML's compiler can terminate the process on ENOSPC. Reserve a
        // conservative preparation budget before downloads or model loading.
        guard try availableStorage(base) >= 8_000_000_000 else {
            throw DictationError.insufficientStorage
        }
        let root = try await prepareModels(model: model, in: base, download: download, progress: progress)
        try Task.checkCancellation()
        let tokens = try await prepareTokenizer(model: model, in: base, download: download, progress: progress)
        try Task.checkCancellation()
        let detectorRoot = try await prepareSpeechDetector(in: base, download: download) {
            progress(0.95 + $0 * 0.05)
        }
        try Task.checkCancellation()
        progress(1)
        let detector = try DictationSpeechDetector(directory: detectorRoot.appendingPathComponent(Self.detectorModel))
        let loaded = try await WhisperKit(WhisperKitConfig(
            modelFolder: root.appendingPathComponent(model.variant).path, tokenizerFolder: tokens,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU),
            verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
        try Task.checkCancellation()
        kit = loaded
        speechDetector = detector
    }

    func prepareModels(model: DictationModel = .turbo, in base: URL, download: Bool,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].flatMap { component in
            Self.coreMLParts.map { component + ".mlmodelc/" + $0 }
        }
        return try await prepareSnapshot(source: Self.modelSource, variant: (model.variant, required),
                                         in: base, download: download) { progress($0 * 0.85) }
    }

    static let detectorModel = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    static let detectorSource = ModelDownloadConfig(modelRepo: "FluidInference/silero-vad-coreml",
                                                    revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96")
    private static let coreMLParts = ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]

    func prepareSpeechDetector(in base: URL, download: Bool,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await prepareSnapshot(source: Self.detectorSource, variant: (Self.detectorModel, Self.coreMLParts),
                                  in: base, download: download, progress: progress)
    }

    private func prepareSnapshot(source: ModelDownloadConfig, variant: (name: String, files: [String]), in base: URL,
                                 download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let downloader = ModelDownloader(config: source)
        let root = downloader.localRepoLocation(downloadBase: base)
        let snapshot = DictationSnapshot(root: root, revision: source.revision,
                                         variant: variant.name, required: variant.files)
        return try await snapshot.prepare(download: download) {
            let hub = HubApiWrapper(downloadBase: base, endpoint: source.endpoint)
            _ = try await hub.snapshot(from: .init(id: source.modelRepo), revision: source.revision,
                                       matching: [variant.name + "/*"]) { progress($0.fractionCompleted) }
        }
    }

    private func prepareTokenizer(model: DictationModel, in base: URL, download: Bool,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let tokenizer = model.tokenizer
        let tokenizers = ModelDownloader(config: ModelDownloadConfig(
            modelRepo: tokenizer.repository, revision: tokenizer.revision))
        let root = tokenizers.localRepoLocation(downloadBase: base)
        // Pinned files verified against that revision's Git blob ids. SDK 1.1.1's
        // cache precheck treats literal file patterns as directories, so validate
        // these two small assets explicitly before allowing an offline reload.
        let files = tokenizer.files
        func valid(_ name: String, _ expected: String) -> Bool {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
        }
        let missing = files.filter { !valid($0.key, $0.value) }
        if missing.isEmpty { return root }
        guard download else { throw DictationError.notReady }
        for name in missing.keys {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        _ = try await tokenizers.resolveRepo(patterns: Array(files.keys), downloadBase: base) {
            progress(0.85 + $0.fractionCompleted * 0.1)
        }
        guard files.allSatisfy({ valid($0.key, $0.value) }) else { throw DictationError.notReady }
        return root
    }

    func transcribe(_ audio: URL) async throws -> String {
        guard let kit, let speechDetector else { throw DictationError.notReady }
        working = true
        defer { working = false }
        var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        guard samples.contains(where: { abs($0) > 0.00001 }) else { return "" }
        guard try speechDetector.containsSpeech(samples) else { return "" }
        if samples.count < 16_000 { samples += Array(repeating: 0, count: 16_000 - samples.count) }
        // Whisper can omit a short utterance that ends at the buffer boundary.
        // Provide a trailing quiet tail after checking the complete clip for speech.
        samples += Array(repeating: 0, count: 8_000)
        try Task.checkCancellation()
        // Timestamp tokens let Whisper resume at the last complete segment,
        // rather than dropping words across fixed 30-second window boundaries.
        let options = DecodingOptions(task: .transcribe, language: nil, detectLanguage: true,
                                      skipSpecialTokens: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Non-speech can decode to punctuation alone. Never insert that noise.
        return text.rangeOfCharacter(from: .alphanumerics) == nil ? "" : text
    }

    func unload() async {
        guard !working else { return }
        let previous = kit
        kit = nil
        speechDetector = nil
        await previous?.unloadModels()
    }
}

enum DictationError: LocalizedError {
    case notReady, microphone, insufficientStorage

    var errorDescription: String? {
        switch self {
        case .notReady: "Dictation isn't ready. Open Settings and try preparing it again."
        case .microphone: "The microphone couldn't start. Check your system input device, then try again."
        case .insufficientStorage: "Free at least 8 GB of disk space, then prepare dictation again in Settings."
        }
    }
}
