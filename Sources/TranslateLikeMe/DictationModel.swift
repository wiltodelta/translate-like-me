import Foundation
import WhisperKit

// Local multilingual speech models with pinned weights and tokenizer assets.
enum DictationModel: String, CaseIterable, Identifiable, Sendable {
    case turbo, qwen3ASR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turbo: "Whisper large-v3-turbo"
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

    // Qwen's list is `support_languages` in the pinned config; Whisper's is its
    // tokenizer's language tokens. DictationLanguageAuditTests checks both against
    // the downloaded files.
    static let qwenLanguages = [
        "Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish", "Portuguese", "Indonesian",
        "Italian", "Korean", "Russian", "Thai", "Vietnamese", "Japanese", "Turkish", "Hindi", "Malay", "Dutch",
        "Swedish", "Danish", "Finnish", "Polish", "Czech", "Filipino", "Persian", "Greek", "Romanian", "Hungarian",
        "Macedonian"
    ]

    private func recognizes(_ identifier: String) -> Bool {
        let preference = DictationLanguagePreference(identifiers: [identifier])
        return switch self {
        case .turbo: !preference.resolvedCodes(supported: Constants.languageCodes).isEmpty
        case .qwen3ASR: !preference.resolvedNames(supported: Self.qwenLanguages).isEmpty
        }
    }

    // Configured languages the model cannot recognize, in their given order, without repeats.
    func unsupported(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted && !recognizes($0) }
    }

    // Prefer the given model; switch only when another recognizes more of the languages.
    static func covering(_ identifiers: [String], preferring preferred: DictationModel) -> DictationModel {
        // min(by:) keeps the first of equals, so the preferred model wins ties.
        let missing = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.unsupported(identifiers).count) })
        return ([preferred] + allCases).min { missing[$0]! < missing[$1]! }!
    }
}
