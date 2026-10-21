import Foundation

// The on-device translation models, 4-bit MLX conversions pinned to the
// revisions measured on an M5 with 32 GB (docs/local-translation.md): of 15
// cases (both directions, a third language, questions, requests, greetings,
// a writing style, Rewrite with a self-correction), TranslateGemma 12B got all
// 15 right at a 3.9 s median; Gemma 4 E2B got 13 at 0.6 s, misplacing the
// self-correction in every Rewrite run, and with the pair written Russian
// first it also translated German into English instead of Russian.
enum LocalModel: String, CaseIterable, Identifiable, Sendable {
    case translateGemma12B = "translategemma-12b"
    case gemma4E2B = "gemma-4-e2b"

    static let `default` = LocalModel.translateGemma12B

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translateGemma12B: "TranslateGemma 12B"
        case .gemma4E2B: "Gemma 4 E2B"
        }
    }

    var summary: String {
        switch self {
        case .translateGemma12B:
            String(localized: """
                The most accurate, writing styles and Rewrite included. About 6.7 GB to download, \
                needs 16 GB of memory.
                """)
        case .gemma4E2B:
            String(localized: """
                About three times faster, and lighter. About 3.6 GB to download. Less accurate: it can \
                translate a third language into the wrong one of your pair, and in Rewrite keep a detail \
                you corrected while speaking.
                """)
        }
    }

    var repository: String {
        switch self {
        case .translateGemma12B: "mlx-community/translategemma-12b-it-4bit"
        case .gemma4E2B: "mlx-community/gemma-4-e2b-it-4bit"
        }
    }

    var revision: String {
        switch self {
        case .translateGemma12B: "f3dcfd54df14672fbcf0731086fb47a797a943ae"
        case .gemma4E2B: "238767527555cb75a05732a84dff5d6ba0dd6809"
        }
    }

    // What MLX and the tokenizer read, with each file's size at `revision`;
    // the repositories' chat templates, model cards and image processor
    // configuration are not downloaded.
    var files: [(name: String, bytes: Int64)] {
        switch self {
        case .translateGemma12B:
            [("config.json", 3_269), ("generation_config.json", 128), ("model.safetensors.index.json", 132_057),
             ("tokenizer.json", 33_384_568), ("tokenizer_config.json", 1_155_413),
             ("model-00001-of-00002.safetensors", 5_367_402_100),
             ("model-00002-of-00002.safetensors", 1_252_261_023)]
        case .gemma4E2B:
            [("config.json", 6_395), ("generation_config.json", 208), ("model.safetensors.index.json", 218_323),
             ("tokenizer.json", 32_169_626), ("tokenizer_config.json", 2_740),
             ("model.safetensors", 3_550_670_554)]
        }
    }

    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    // Peak memory measured while translating was 7.5 GB and 3.3 GB; a Mac
    // needs room for that beside the apps the user is translating from.
    var minimumMemory: UInt64 {
        switch self {
        case .translateGemma12B: 16 << 30
        case .gemma4E2B: 8 << 30
        }
    }

    func fits(physicalMemory: UInt64) -> Bool { physicalMemory >= minimumMemory }

    // The turn markers each model was trained on. TranslateGemma's template
    // takes no system turn, so the instructions open the user turn, as in the
    // benchmark; Gemma 4's thinking stays off, since its template otherwise
    // starts a reasoning channel instead of the translation.
    func prompt(system: String, text: String) -> String {
        let input = Self.removingControlTokens(from: text)
        switch self {
        case .translateGemma12B:
            return "<bos><start_of_turn>user\n\(system)\n\n\(input)<end_of_turn>\n<start_of_turn>model\n"
        case .gemma4E2B:
            return "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\n\(input)<turn|>\n<|turn>model\n"
        }
    }

    // The tokens that end the answer. The MLX conversions list only <eos>, so
    // without the turn terminator a model generated until the token limit.
    static let stopTokens: Set<String> = ["<end_of_turn>", "<turn|>", "<eos>"]

    // The tokenizer matches special tokens anywhere in the prompt string, so a
    // selection holding one could close the user turn and speak as the model.
    private static let controlTokens = ["<bos>", "<eos>", "<start_of_turn>", "<end_of_turn>", "<|turn>", "<turn|>"]

    static func removingControlTokens(from text: String) -> String {
        controlTokens.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
    }

    // Room for a translation several times longer than its source (tokens per
    // character differ by script), never less than a short reply needs.
    static func maxTokens(inputCharacters: Int) -> Int {
        min(8192, max(256, inputCharacters * 2))
    }
}
