import Foundation

enum APIError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse
    case noModel

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "No API key set for \(provider). Add it in Settings."
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "API error \(code): \(trimmed.isEmpty ? "no details" : trimmed)"
        case .badResponse:
            return "Could not parse the API response."
        case .noModel:
            return "Select a model first (use Refresh in Settings)."
        }
    }
}

// Direct HTTP access to the Anthropic and OpenAI APIs (API-key mode).
enum APIClient {
    static func anthropicTranslate(key: String, model: String, system: String, text: String) async throws -> String {
        guard !key.isEmpty else { throw APIError.missingKey("Anthropic") }
        // Default to the latest Sonnet when the user hasn't picked a model.
        let modelID = model.isEmpty ? "claude-sonnet-4-6" : model

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": text]]
        ]
        var request = makeRequest("https://api.anthropic.com/v1/messages", method: "POST")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendJSON(request)
        guard let content = json["content"] as? [[String: Any]] else { throw APIError.badResponse }
        let result = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        guard !result.isEmpty else { throw APIError.badResponse }
        return result
    }

    static func openaiTranslate(key: String, model: String, system: String, text: String) async throws -> String {
        guard !key.isEmpty else { throw APIError.missingKey("OpenAI") }
        guard !model.isEmpty else { throw APIError.noModel }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ]
        ]
        var request = makeRequest("https://api.openai.com/v1/chat/completions", method: "POST")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendJSON(request)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIError.badResponse
        }
        return content
    }

    // Returns the account's model ids, newest first (by creation date). Used to
    // resolve the latest model live, instead of pinning an id in the app.
    static func listModels(provider: Provider, key: String) async throws -> [String] {
        guard !key.isEmpty else { throw APIError.missingKey(provider.displayName) }

        let urlString = provider == .anthropic
            ? "https://api.anthropic.com/v1/models?limit=1000"
            : "https://api.openai.com/v1/models"
        var request = makeRequest(urlString, method: "GET")
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let json = try await sendJSON(request)
        guard let data = json["data"] as? [[String: Any]] else { throw APIError.badResponse }

        // Sort newest first. Anthropic returns ISO `created_at`; OpenAI a unix `created`.
        let sorted = data.sorted { lhs, rhs in recency(lhs) > recency(rhs) }
        return sorted.compactMap { $0["id"] as? String }
    }

    private static func recency(_ item: [String: Any]) -> Double {
        if let unix = item["created"] as? Double { return unix }
        if let unix = item["created"] as? Int { return Double(unix) }
        if let iso = item["created_at"] as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: iso) { return date.timeIntervalSince1970 }
        }
        return 0
    }

    // MARK: - Plumbing

    private static func makeRequest(_ url: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        return json
    }
}
