import Foundation

// The error thrown when the engine's usage limit is exhausted: a subscription
// weekly/5-hour limit in CLI mode, or a 429 quota/rate limit in API mode.
// Carrying it as its own type lets the UI present the reset time and a
// switch-engine action instead of a generic error.
struct LimitReachedError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

// Pulls a human message out of a JSON error object embedded in engine output
// (any `{...}` span), trying data.message, error.message, and message.
// Shared by the CLI layer (Translator) and the API layer (APIClient).
enum JSONErrorMessage {
    static func extract(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let slice = String(text[start...end])
        guard let json = try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any] else {
            return nil
        }
        if let data = json["data"] as? [String: Any], let message = data["message"] as? String {
            return message
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return (json["message"] as? String)
    }
}

// Recognizes limit-exhaustion failures in engine output. Patterns come from
// real payloads captured 2026-08-17 against exhausted subscriptions:
//   claude -p    stdout, exit 1:
//     "You've hit your weekly limit · resets Aug 19 at 10pm (America/Los_Angeles)"
//     ("You've hit your 5-hour limit · resets at ..." is the rolling variant)
//   codex exec   stderr, exit 1, printed twice after a session header:
//     "ERROR: You've hit your usage limit. Visit
//      https://chatgpt.com/codex/settings/usage to purchase more credits or
//      try again at Aug 19th, 2026 8:29 PM."
//   Anthropic/OpenAI API 429 bodies ("...would exceed your monthly text-token
//   limit", "You exceeded your current quota...").
enum LimitDetector {
    // A line matches when it contains every phrase of some pair,
    // case-insensitive, with "_" counted as a space so JSON keys like
    // rate_limit_error match the prose patterns too.
    private static let markers: [[String]] = [
        ["hit your", "limit"],
        ["reached your", "limit"],
        ["usage limit"],
        ["exceed", "limit"],
        ["exceeded", "quota"],
        ["rate limit"]
    ]

    // The first matching line, cleaned of CLI prefixes, or nil when the text
    // is not a limit failure. Taking the first match also deduplicates codex,
    // which prints its limit line twice.
    static func message(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let normalized = line.replacingOccurrences(of: "_", with: " ").lowercased()
            guard markers.contains(where: { $0.allSatisfy { normalized.contains($0) } }) else {
                continue
            }
            var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["ERROR:", "\u{26A0}\u{FE0F}", "\u{26A0}"] where cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            return cleaned
        }
        return nil
    }
}
