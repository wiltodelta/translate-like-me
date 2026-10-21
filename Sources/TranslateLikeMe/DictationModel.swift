import Foundation

// Local multilingual speech models with pinned weights and tokenizer assets.
enum DictationModel: String, CaseIterable, Identifiable, Sendable {
    case turbo, qwen3ASR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turbo: String(localized: "Whisper Turbo")
        case .qwen3ASR: "Qwen3-ASR 1.7B (8-bit)"
        }
    }

    var summary: String {
        switch self {
        case .turbo: String(localized: "For everyday dictation. About 627 MB to download.")
        case .qwen3ASR: String(localized: "Supports 30 languages. About 2.5 GB to download.")
        }
    }

    // Directory inside the pinned repository.
    var variant: String {
        switch self {
        case .turbo: "openai_whisper-large-v3-v20240930_626MB"
        case .qwen3ASR: ""
        }
    }

    struct Tokenizer: Sendable {
        let repository: String
        let revision: String
        let files: [String: String]
    }

    var tokenizer: Tokenizer? {
        switch self {
        case .qwen3ASR: nil
        case .turbo:
            Tokenizer(repository: "openai/whisper-large-v3-turbo", revision: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
                      files: [
                        "tokenizer.json": "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd",
                        "tokenizer_config.json": "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"
                      ])
        }
    }
}
