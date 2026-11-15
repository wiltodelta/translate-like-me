import Foundation

// Qwen's greedy token loop stays in the calling task, so cancellation drains
// inference before the controller permits another session or runtime unload.
enum DictationQwenDecoding {
    enum Failure: Error, Equatable { case tokenLimit(Int), repetition(Int) }
    enum HeaderOutcome: Equatable {
        case language(String)
        case noSpeech
        case fallback
    }

    static func decode(endTokens: Set<Int>, maximumTokens: Int = 1024,
                       next: (Int?) throws -> Int) throws -> [Int] {
        var tokens: [Int] = []
        for _ in 0..<maximumTokens {
            try Task.checkCancellation()
            let token = try next(tokens.last)
            if endTokens.contains(token) { return tokens }
            tokens.append(token)
            // Match the SDK's greedy repetition backstop, but report an error
            // instead of delivering a silently truncated transcript.
            if tokens.count >= 24, Set(tokens.suffix(24)).count <= 3 { throw Failure.repetition(tokens.count) }
        }
        throw Failure.tokenLimit(tokens.count)
    }

    static func transcript(_ source: String) -> String {
        if let header = splitHeader(source) { return header.body }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func headerOutcome(_ source: String, supported: [String]) -> HeaderOutcome {
        guard let header = splitHeader(source), !header.language.isEmpty else { return .fallback }
        if header.language.caseInsensitiveCompare("None") == .orderedSame { return .noSpeech }
        if let match = supported.first(where: { $0.caseInsensitiveCompare(header.language) == .orderedSame }) {
            return .language(match)
        }
        return .fallback
    }

    private static func splitHeader(_ source: String) -> (language: String, body: String)? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("language "), let marker = text.range(of: "<asr_text>") else { return nil }
        let start = text.index(text.startIndex, offsetBy: "language ".count)
        let language = text[start..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (language, body)
    }
}
