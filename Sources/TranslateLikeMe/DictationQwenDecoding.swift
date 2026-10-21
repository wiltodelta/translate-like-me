import Foundation

// Qwen's greedy token loop stays in the calling task, so cancellation drains
// inference before the controller permits another session or runtime unload.
enum DictationQwenDecoding {
    enum Failure: Error { case limit }

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
            if tokens.count >= 24, Set(tokens.suffix(24)).count <= 3 { throw Failure.limit }
        }
        throw Failure.limit
    }

    static func transcript(_ source: String) -> String {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("language "), let marker = text.range(of: "<asr_text>") else { return text }
        return String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
