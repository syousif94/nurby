import Foundation

/// A minimal OpenRouter client: the model list and non-streaming chat completions with tools
/// (OpenAI-compatible format).
enum OpenRouter {
    static let base = URL(string: "https://openrouter.ai/api/v1")!

    struct Model: Decodable {
        let id: String
        let name: String
        let context_length: Int?
        let supported_parameters: [String]?
        let architecture: Architecture?
        struct Architecture: Hashable, Decodable { let input_modalities: [String]? }
        var acceptsImages: Bool { architecture?.input_modalities?.contains("image") ?? false }
        var supportsTools: Bool { supported_parameters?.contains("tools") ?? false }
        var info: ModelInfo { ModelInfo(id: id, name: name, acceptsImages: acceptsImages) }
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Every model OpenRouter lists that can call tools (needed to drive the CAD kernel).
    static func toolModels() async throws -> [ModelInfo] {
        struct List: Decodable { let data: [Model] }
        let (data, resp) = try await URLSession.shared.data(from: base.appending(path: "models"))
        try check(resp, data)
        return try JSONDecoder().decode(List.self, from: data).data.filter(\.supportsTools).map(\.info)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Checks a key against OpenRouter; returns its label and remaining credit, if any.
    static func checkKey(_ key: String) async throws -> String {
        var req = URLRequest(url: base.appending(path: "key"))
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
        if let limit = obj?["limit_remaining"] as? Double { return String(format: "Key works · $%.2f left", limit) }
        return "Key works"
    }

    /// One chat completion. `messages` and `tools` are OpenAI-format JSON objects.
    @MainActor static func complete(key: String, model: String, messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        var req = URLRequest(url: base.appending(path: "chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Nurby", forHTTPHeaderField: "X-Title")
        // Keys starting with "_" are the app's own notes (e.g. Claude API content blocks), not OpenAI fields.
        let clean = messages.map { $0.filter { !$0.key.hasPrefix("_") } }
        var body: [String: Any] = ["model": model, "messages": clean]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "OpenRouter sent something that isn't JSON")
        }
        if let err = obj["error"] as? [String: Any] { throw APIError(message: err["message"] as? String ?? "OpenRouter error") }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw APIError(message: "OpenRouter returned no answer")
        }
        return message
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
        throw APIError(message: "OpenRouter \(http.statusCode): \(msg)")
    }
}
