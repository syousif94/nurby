import Foundation

/// Where the agent's model runs: Claude through the Claude API with an Anthropic API key, or any
/// tool-calling model through OpenRouter. Each keeps its own key (Keychain) and chosen model.
enum Provider: String, CaseIterable, Identifiable {
    case anthropic, openRouter

    var id: String { rawValue }
    var title: String { self == .anthropic ? "Claude API" : "OpenRouter" }
    var keyName: String { self == .anthropic ? "Anthropic API key" : "OpenRouter API key" }
    /// Keychain account the key is stored under.
    var keyAccount: String { self == .anthropic ? "anthropic" : "openrouter" }
    var keyPlaceholder: String { self == .anthropic ? "sk-ant-…" : "sk-or-…" }
    var host: String { self == .anthropic ? "api.anthropic.com" : "openrouter.ai" }
    var keysURL: URL {
        URL(string: self == .anthropic ? "https://platform.claude.com/settings/keys" : "https://openrouter.ai/keys")!
    }
    var keysLabel: String { self == .anthropic ? "platform.claude.com" : "openrouter.ai/keys" }
}

/// A model the agent can run on, from either provider's model list.
struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    var acceptsImages: Bool
    /// Claude API only: whether the model takes `output_config.effort`.
    var supportsEffort = false

    var shortName: String { name.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? name }
}

/// A minimal Claude API client: the model list and non-streaming Messages API calls with tools.
/// Swift has no official Anthropic SDK, so this is raw HTTP.
///
/// The agent keeps its conversation in OpenAI chat format (what OpenRouter takes); this converts it to
/// Messages API format on the way out and converts each reply back. A reply's own content blocks
/// (thinking blocks included) are kept on the assistant message under `_anthropic` and sent back
/// unchanged, as the Messages API requires.
enum Anthropic {
    static let base = URL(string: "https://api.anthropic.com/v1")!
    static let version = "2026-10-21"
    /// Models that take server-side refusal fallbacks (`fallbacks: "default"`).
    private static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The models this key can use, newest first (the order the Models API lists them in).
    static func models(key: String) async throws -> [ModelInfo] {
        var out: [ModelInfo] = []
        var after: String?
        repeat {
            var comps = URLComponents(url: base.appending(path: "models"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "limit", value: "100")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            let (data, resp) = try await URLSession.shared.data(for: request(comps.url!, key: key))
            try check(resp, data)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            for m in obj["data"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String else { continue }
                let caps = m["capabilities"] as? [String: Any]
                func supported(_ name: String) -> Bool { (caps?[name] as? [String: Any])?["supported"] as? Bool ?? false }
                out.append(ModelInfo(id: id, name: m["display_name"] as? String ?? id,
                                     acceptsImages: caps == nil ? true : supported("image_input"),
                                     supportsEffort: supported("effort")))
            }
            after = (obj["has_more"] as? Bool ?? false) ? obj["last_id"] as? String : nil
        } while after != nil
        return out
    }

    /// Checks a key by listing models with it.
    static func checkKey(_ key: String) async throws -> String {
        let n = try await models(key: key).count
        return "Key works · \(n) models"
    }

    /// One Messages API call. `history` and `tools` are in the agent's OpenAI chat format; the reply
    /// comes back in that format too (`content`, `tool_calls`), with the raw blocks under `_anthropic`.
    @MainActor static func complete(key: String, model: ModelInfo, system: String, history: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        var req = request(base.appending(path: "messages"), key: key)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 16000,
            "system": system,
            "messages": messages(from: history),
            // Caches the tools, system prompt and conversation so far: each step of the tool loop
            // resends all of it.
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty { body["tools"] = tools.compactMap(tool(from:)) }
        // Modelling is multi-step agentic work: think harder than Claude Opus 5.5's `medium` default.
        if model.supportsEffort { body["output_config"] = ["effort": "high"] }
        if fallbackModels.contains(model.id) {
            // A safety-classifier decline re-runs on Anthropic's recommended fallback model instead.
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "The Claude API sent something that isn't JSON")
        }
        let content = obj["content"] as? [[String: Any]] ?? []
        switch obj["stop_reason"] as? String {
        case "refusal":
            let why = ((obj["stop_details"] as? [String: Any])?["explanation"] as? String).map { ": \($0)" } ?? "."
            throw APIError(message: "Claude declined this request\(why) Try rephrasing it, or another model.")
        case "max_tokens" where content.contains(where: { $0["type"] as? String == "tool_use" }):
            throw APIError(message: "Claude's reply was cut off mid-step. Say “continue” to try again.")
        default: break
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        let calls: [[String: Any]] = content.filter { $0["type"] as? String == "tool_use" }.map { b in
            let input = b["input"] ?? [String: Any]()
            let args = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ["id": b["id"] as? String ?? UUID().uuidString, "type": "function",
                    "function": ["name": b["name"] as? String ?? "", "arguments": args]]
        }
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text, "_anthropic": content]
        if !calls.isEmpty { message["tool_calls"] = calls }
        return message
    }

    // MARK: Format conversion

    /// OpenAI-format function tool → Messages API tool.
    private static func tool(from t: [String: Any]) -> [String: Any]? {
        guard let fn = t["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
        return ["name": name, "description": fn["description"] as? String ?? "",
                "input_schema": fn["parameters"] ?? ["type": "object", "properties": [String: Any]()]]
    }

    /// OpenAI-format history → Messages API messages: tool results become `tool_result` blocks in a user
    /// turn, consecutive same-role turns merge, and a tool call left without a result (a stopped run)
    /// gets an error result so the conversation stays valid.
    static func messages(from history: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pending: [String] = []          // tool_use ids from the last assistant turn
        var results: [[String: Any]] = []   // their tool_result blocks, so far

        func push(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if out.last?["role"] as? String == role, let prev = out.last?["content"] as? [[String: Any]] {
                out[out.count - 1]["content"] = prev + blocks
            } else {
                out.append(["role": role, "content": blocks])
            }
        }
        // Tool results go first in the user turn after the calls; unanswered calls get an error result.
        func closeTools() {
            let answered = Set(results.compactMap { $0["tool_use_id"] as? String })
            let stubs: [[String: Any]] = pending.filter { !answered.contains($0) }.map {
                ["type": "tool_result", "tool_use_id": $0, "content": "Not run: the person stopped the agent.", "is_error": true]
            }
            push("user", results + stubs)
            results = []
            pending = []
        }

        for m in history {
            switch m["role"] as? String {
            case "tool":
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": m["tool_call_id"] as? String ?? "",
                                            "content": m["content"] as? String ?? ""]
                if m["_is_error"] as? Bool == true { block["is_error"] = true }
                results.append(block)
            case "user":
                closeTools()
                push("user", userBlocks(m["content"]))
            case "assistant":
                closeTools()
                let blocks: [[String: Any]]
                if let raw = m["_anthropic"] as? [[String: Any]] {
                    blocks = raw
                } else {
                    var b: [[String: Any]] = []
                    if let text = m["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        b.append(["type": "text", "text": text])
                    }
                    for call in m["tool_calls"] as? [[String: Any]] ?? [] {
                        let fn = call["function"] as? [String: Any] ?? [:]
                        let args = (fn["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
                        b.append(["type": "tool_use", "id": call["id"] as? String ?? UUID().uuidString,
                                  "name": fn["name"] as? String ?? "", "input": args ?? [String: Any]()])
                    }
                    blocks = b
                }
                push("assistant", blocks)
                pending = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            default:
                continue
            }
        }
        closeTools()
        return out
    }

    /// A user turn's content (a string, or OpenAI text / image_url parts) → Messages API blocks,
    /// pictures first.
    private static func userBlocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String { return text.isEmpty ? [] : [["type": "text", "text": text]] }
        var images: [[String: Any]] = []
        var texts: [[String: Any]] = []
        for part in content as? [[String: Any]] ?? [] {
            if let text = part["text"] as? String {
                texts.append(["type": "text", "text": text])
            } else if let url = (part["image_url"] as? [String: Any])?["url"] as? String,
                      url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
                let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
                let media = header.split(separator: ";").first.map(String.init) ?? "image/jpeg"
                images.append(["type": "image", "source": ["type": "base64", "media_type": media, "data": String(url[url.index(after: comma)...])]])
            }
        }
        return images + texts
    }

    /// Thinking blocks are bound to the exact conversation they were made in. When saved history has
    /// been changed (pictures dropped), the blocks after the change are no longer valid: strip them.
    static func strippingThinking(_ history: [[String: Any]]) -> [[String: Any]] {
        history.map { m in
            guard let raw = m["_anthropic"] as? [[String: Any]] else { return m }
            var copy = m
            copy["_anthropic"] = raw.filter { !["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
            return copy
        }
    }

    // MARK: HTTP

    private static func request(_ url: URL, key: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        return req
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
        throw APIError(message: "Claude API \(http.statusCode): \(msg)")
    }
}
