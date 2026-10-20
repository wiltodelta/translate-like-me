import Foundation

// Multilingual Core ML models. Whisper keeps its matching tokenizer in a
// separate pinned cache; Parakeet includes its vocabulary in the model snapshot.
enum DictationModel: String, CaseIterable, Identifiable, Sendable {
    case small, turbo, largeV3, parakeetUltra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Whisper Small"
        case .turbo: "Whisper Large v3 Turbo"
        case .largeV3: "Whisper Large v3"
        case .parakeetUltra: "Parakeet Ultra"
        }
    }

    var summary: String {
        switch self {
        case .small: String(localized: "Uses less memory. About 487 MB to download.")
        case .turbo: String(localized: "For everyday dictation. About 627 MB to download.")
        case .largeV3: String(localized: "Full-size model. About 948 MB to download.")
        case .parakeetUltra: String(localized: "Fast dictation in 25 European languages. About 632 MB to download.")
        }
    }

    // Directory inside the pinned repository; Parakeet uses the repository root.
    var variant: String {
        switch self {
        case .small: "openai_whisper-small"
        case .turbo: "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3: "openai_whisper-large-v3_947MB"
        case .parakeetUltra: ""
        }
    }

    struct Tokenizer: Sendable {
        let repository: String
        let revision: String
        let files: [String: String]
    }

    var tokenizer: Tokenizer? {
        switch self {
        case .parakeetUltra: nil
        case .small:
            Tokenizer(repository: "openai/whisper-small", revision: "973afd24965f72e36ca33b3055d56a652f456b4d",
                      files: [
                        "tokenizer.json": "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566",
                        "tokenizer_config.json": "2a4c4281cf9f51ac6ccc406fdc711a087afe6530f671fa7b80953edc498275ce"
                      ])
        case .turbo:
            Tokenizer(repository: "openai/whisper-large-v3-turbo", revision: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
                      files: [
                        "tokenizer.json": "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd",
                        "tokenizer_config.json": "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"
                      ])
        case .largeV3:
            Tokenizer(repository: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
                      files: [
                        "tokenizer.json": "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca",
                        "tokenizer_config.json": "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"
                      ])
        }
    }
}
