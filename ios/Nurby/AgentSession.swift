import Foundation
import Observation
import UIKit

/// The design agent: Claude (Claude API) or an OpenRouter model, driving SolidCraft through the same MCP tools
/// SolidCraft's own agents use (`execute`, `batch`, `inspect_design`, `measure`…).
@MainActor @Observable
final class AgentSession {
    struct Entry: Identifiable {
        enum Kind { case user, agent, tool(ok: Bool), error }
        let id = UUID()
        let kind: Kind
        var text: String
        var context: String? = nil
        var images: [UIImage] = []
    }

    /// A saved conversation (Application Support/Chats/<id>.json): what the recent-chats list shows.
    struct Chat: Identifiable, Hashable {
        let id: UUID
        let title: String
        let design: String
        let updated: Date
        var file: URL? = nil
    }

    private(set) var entries: [Entry] = []
    private(set) var busy = false
    /// Saved conversations, newest first.
    private(set) var recentChats: [Chat] = []
    private var chatID = UUID()
    private var chatDesign = ""
    private var history: [[String: Any]] = []
    private var tools: [[String: Any]] = []
    private var task: Task<Void, Never>?

    /// Where the model runs. Each provider keeps its own key, model and recent models.
    var provider: Provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "")
        ?? (Keychain.read(Provider.openRouter.keyAccount) != nil ? .openRouter : .anthropic) {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            models = []
            modelError = nil
        }
    }
    private var keys: [Provider: String] = Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { p in Keychain.read(p.keyAccount).map { (p, $0) } })
    private var chosen: [Provider: String] = Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { p in
        UserDefaults.standard.string(forKey: AgentSession.defaultsKey("model", p)).map { (p, $0) } })
    private var recents: [Provider: [String]] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { p in
        (p, UserDefaults.standard.stringArray(forKey: AgentSession.defaultsKey("recentModels", p)) ?? []) })

    /// OpenRouter keeps the original UserDefaults names, so existing settings carry over.
    private static func defaultsKey(_ name: String, _ p: Provider) -> String { p == .openRouter ? name : "\(name).\(p.rawValue)" }

    /// The current provider's key (Keychain).
    var apiKey: String? {
        get { keys[provider] }
        set {
            keys[provider] = newValue?.isEmpty == false ? newValue : nil
            Keychain.write(provider.keyAccount, keys[provider])
            if provider == .anthropic { models = [] }
        }
    }
    func hasKey(_ p: Provider) -> Bool { !(keys[p] ?? "").isEmpty }
    var hasKey: Bool { hasKey(provider) }

    /// The current provider's model id.
    var model: String {
        get { chosen[provider] ?? "" }
        set {
            chosen[provider] = newValue
            UserDefaults.standard.set(newValue, forKey: AgentSession.defaultsKey("model", provider))
            guard !newValue.isEmpty else { return }
            recents[provider] = Array(([newValue] + recentModels.filter { $0 != newValue }).prefix(5))
            UserDefaults.standard.set(recents[provider], forKey: AgentSession.defaultsKey("recentModels", provider))
        }
    }
    /// The last few models used with this provider, newest first (the composer's quick model menu).
    var recentModels: [String] { recents[provider] ?? [] }
    /// The provider's models (tool-calling ones for OpenRouter), loaded once for names and image support.
    private(set) var models: [ModelInfo] = []
    private(set) var modelError: String?
    private var loadingModels = false

    func loadModels(force: Bool = false) async {
        guard force || models.isEmpty, !loadingModels else { return }
        let p = provider
        if p == .anthropic && !hasKey(p) { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let list = p == .anthropic ? try await Anthropic.models(key: keys[p] ?? "") : try await OpenRouter.toolModels()
            guard p == provider else { return }
            models = list
            modelError = nil
            if model.isEmpty || (!list.isEmpty && !list.contains(where: { $0.id == model })) { model = Self.defaultModel(list, p) ?? "" }
        } catch {
            if p == provider { modelError = "Couldn't load models: \(error.localizedDescription)" }
        }
    }

    /// A strong default: Claude Opus 5.5 on the Claude API; on OpenRouter the newest Claude Sonnet,
    /// else Claude Opus, else the first listed.
    static func defaultModel(_ models: [ModelInfo], _ p: Provider) -> String? {
        if p == .anthropic {
            return ["claude-opus-5-5", "claude-sonnet-5-5"].first { id in models.contains { $0.id == id } } ?? models.first?.id
        }
        for family in ["anthropic/claude-sonnet", "anthropic/claude-opus"] {
            if let m = models.map(\.id).filter({ $0.hasPrefix(family) && !$0.contains(":") }).sorted(by: >).first { return m }
        }
        return models.first(where: { !$0.id.contains(":") })?.id
    }

    func info(_ id: String) -> ModelInfo? { models.first { $0.id == id } }

    /// A short display name for a model id ("Claude Sonnet 4.5" rather than "anthropic/claude-sonnet-4.5").
    func displayName(_ id: String) -> String {
        if let m = info(id) { return m.shortName }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Whether the current model can see attached images (unknown counts as yes).
    var modelSeesImages: Bool { info(model)?.acceptsImages ?? true }

    /// Well-known tool models offered in the quick menu when they are listed.
    var suggestedModels: [String] {
        if provider == .anthropic {
            return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-haiku-5-5"].filter { id in models.contains { $0.id == id } }
        }
        let wanted = ["anthropic/claude-sonnet", "anthropic/claude-opus", "openai/gpt-5", "google/gemini-3"]
        var out: [String] = []
        for prefix in wanted {
            if let m = models.map(\.id).filter({ $0.hasPrefix(prefix) && !$0.contains(":") }).sorted(by: >).first, !out.contains(m) { out.append(m) }
        }
        return out
    }

    private let maxSteps = 60
    private let maxToolText = 24_000

    init() { loadRecentChats() }

    func newChat() {
        stop()
        entries = []
        history = []
        chatID = UUID()
    }

    // MARK: Saved chats

    private static var chatsDir: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Chats", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let keepChats = 40

    /// Pick up a saved conversation where it left off (pictures aren't kept, only their mention).
    func open(_ chat: Chat) {
        stop()
        guard let data = try? Data(contentsOf: chat.file ?? Self.chatsDir.appending(path: "\(chat.id.uuidString).json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        entries = (obj["entries"] as? [[String: Any]] ?? []).compactMap { e in
            let text = e["t"] as? String ?? ""
            let kind: Entry.Kind
            switch e["k"] as? String {
            case "user": kind = .user
            case "agent": kind = .agent
            case "tool": kind = .tool(ok: true)
            case "toolError": kind = .tool(ok: false)
            case "error": kind = .error
            default: return nil
            }
            return Entry(kind: kind, text: text, context: e["c"] as? String)
        }
        history = obj["history"] as? [[String: Any]] ?? []
        // Saving dropped the pictures, which changes the conversation Claude's thinking blocks were made in.
        if history.contains(where: { ($0["content"] as? String)?.hasSuffix("[picture not kept]") == true }) {
            history = Anthropic.strippingThinking(history)
        }
        chatID = chat.id
        chatDesign = chat.design
    }

    func delete(_ chat: Chat) {
        try? FileManager.default.removeItem(at: chat.file ?? Self.chatsDir.appending(path: "\(chat.id.uuidString).json"))
        if chat.id == chatID { newChat() }
        loadRecentChats()
    }

    private func saveChat() {
        guard let first = entries.first(where: { if case .user = $0.kind { true } else { false } }) else { return }
        let encoded: [[String: Any]] = entries.map { e in
            let k: String
            switch e.kind {
            case .user: k = "user"
            case .agent: k = "agent"
            case .tool(let ok): k = ok ? "tool" : "toolError"
            case .error: k = "error"
            }
            var out: [String: Any] = ["k": k, "t": e.text]
            if let c = e.context { out["c"] = c }
            return out
        }
        // Pictures are large: keep the words, note that a picture was there.
        let slim: [[String: Any]] = history.map { m in
            guard let parts = m["content"] as? [[String: Any]] else { return m }
            var copy = m
            copy["content"] = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") + "\n[picture not kept]"
            return copy
        }
        let obj: [String: Any] = ["id": chatID.uuidString, "title": String(first.text.prefix(80)), "design": chatDesign,
                                  "updated": Date().timeIntervalSince1970, "entries": encoded, "history": slim]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: Self.chatsDir.appending(path: "\(chatID.uuidString).json"), options: .atomic)
        }
        loadRecentChats()
    }

    private func loadRecentChats() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.chatsDir, includingPropertiesForKeys: nil)) ?? []
        var chats: [(Chat, URL)] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (obj["id"] as? String).flatMap(UUID.init) else { continue }
            chats.append((Chat(id: id, title: obj["title"] as? String ?? "Chat", design: obj["design"] as? String ?? "",
                               updated: Date(timeIntervalSince1970: obj["updated"] as? Double ?? 0), file: url), url))
        }
        chats.sort { $0.0.updated > $1.0.updated }
        for (_, url) in chats.dropFirst(Self.keepChats) { try? FileManager.default.removeItem(at: url) }
        recentChats = chats.prefix(Self.keepChats).map(\.0)
    }

    func stop() {
        task?.cancel()
        task = nil
        busy = false
    }

    /// Whether the agent's current turn changed the design.
    private var turnChanged = false

    /// A version name from the request: its first line, cut to a few words.
    private static func versionTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Sends a message; false if it couldn't be sent (busy, no key or no model), so the composer keeps it.
    @discardableResult
    func send(_ text: String, images: [UIImage] = [], design: DesignModel) -> Bool {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && !images.isEmpty { text = "Here is a picture." }
        guard !text.isEmpty, !busy else { return false }
        guard let key = apiKey, !key.isEmpty else {
            entries.append(.init(kind: .error, text: "Add your \(provider.keyName) in Settings first."))
            return false
        }
        guard !model.isEmpty else {
            entries.append(.init(kind: .error, text: "Pick a model first."))
            return false
        }
        let picks = design.selection
        let caption = picks.isEmpty ? nil : "with " + picks.map(\.label).joined(separator: ", ")
        entries.append(.init(kind: .user, text: text, context: caption, images: images))
        chatDesign = design.name
        var content = text
        if !picks.isEmpty {
            content += "\n\n[Selected in the viewport, and set as SolidCraft's current selection: "
                + picks.map { p in p.context + (design.pickOrigins[p.id].map { o in o.isEmpty ? "" : ", made by " + o.map { "\"\($0.name)\"" }.joined(separator: " and ") } ?? "") }.joined(separator: "; ") + ". Face and edge indices are the ones select.set and inspect_design use.]"
        }
        if images.isEmpty {
            history.append(["role": "user", "content": content])
        } else {
            content += "\n\n[\(images.count == 1 ? "An image is" : "\(images.count) images are") attached. A picture of the viewport, "
                + "possibly with pen markup drawn on it, shows what the person is pointing at.]"
            var parts: [[String: Any]] = [["type": "text", "text": content]]
            for img in images {
                if let url = Self.dataURL(img) { parts.append(["type": "image_url", "image_url": ["url": url]]) }
            }
            history.append(["role": "user", "content": parts])
        }
        busy = true
        let provider = provider
        turnChanged = false
        let title = Self.versionTitle(text)
        task = Task { [weak self] in
            await self?.loop(provider: provider, key: key, design: design)
            // Each turn that changed the design is a version, so it can be compared or undone.
            if self?.turnChanged == true { await design.saveVersion(named: title, author: "Agent") }
            self?.busy = false
            self?.saveChat()
        }
        return true
    }

    private func loop(provider: Provider, key: String, design: DesignModel) async {
        let studio = design.studio
        if tools.isEmpty {
            tools = Self.openAITools(from: (try? studio.toolsJson()) ?? "[]")
        }
        let system = Self.systemPrompt(studio.instructions())
        for _ in 0..<maxSteps {
            if Task.isCancelled { return }
            let message: [String: Any]
            do {
                switch provider {
                case .anthropic:
                    let m = info(model) ?? ModelInfo(id: model, name: model, acceptsImages: true)
                    message = try await Anthropic.complete(key: key, model: m, system: system, history: history, tools: tools)
                case .openRouter:
                    message = try await OpenRouter.complete(key: key, model: model, messages: [["role": "system", "content": system]] + history, tools: tools)
                }
            } catch {
                if !Task.isCancelled { entries.append(.init(kind: .error, text: error.localizedDescription)) }
                return
            }
            if Task.isCancelled { return }
            var kept: [String: Any] = ["role": "assistant", "content": message["content"] ?? NSNull()]
            if let raw = message["_anthropic"] { kept["_anthropic"] = raw }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if !calls.isEmpty { kept["tool_calls"] = calls }
            history.append(kept)
            if let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(.init(kind: .agent, text: text))
            }
            if calls.isEmpty { return }

            var changed = false
            for call in calls {
                let id = call["id"] as? String ?? UUID().uuidString
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let args = fn["arguments"] as? String ?? "{}"
                let label = Self.label(name, args)
                let i = entries.count
                entries.append(.init(kind: .tool(ok: true), text: label + "…"))
                let result = await Task.detached { () -> ToolResult in
                    do { return try studio.callTool(name: name, argsJson: args) } catch { return ToolResult(text: "\(error)", isError: true) }
                }.value
                entries[i] = .init(kind: .tool(ok: !result.isError), text: result.isError ? "\(label): \(result.text.prefix(200))" : label)
                var text = result.text
                if text.count > maxToolText {
                    text = String(text.prefix(maxToolText)) + "\n…[cut: \(text.count - maxToolText) more characters; ask for less, e.g. with filter/limit/compact]"
                }
                var toolMessage: [String: Any] = ["role": "tool", "tool_call_id": id, "content": text]
                if result.isError { toolMessage["_is_error"] = true }
                history.append(toolMessage)
                if !Self.readOnly.contains(name) { changed = true }
            }
            if changed { turnChanged = true; await design.refresh() }
        }
        entries.append(.init(kind: .error, text: "Stopped after \(maxSteps) steps. Say “continue” to keep going."))
    }

    /// JPEG, at most 1568 px on the long side (what vision models use at full detail).
    private static func dataURL(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 1568
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let k = min(1, maxSide / max(px.width, px.height, 1))
        let size = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = scaled.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private static let readOnly: Set<String> = ["version", "list_commands", "describe_command", "inspect_design", "measure",
                                                "body_topology", "skill_reference", "screenshot", "running", "pending", "check_parameters"]

    /// A short line for the chat: the tool and, for `execute`, the command it ran.
    private static func label(_ name: String, _ args: String) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
        if name == "execute", let c = obj?["command"] as? String { return c }
        if name == "batch", let steps = obj?["steps"] as? [Any] { return "batch · \(steps.count) steps" }
        if name == "describe_command", let c = obj?["id"] as? String { return "describe \(c)" }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    private static func openAITools(from json: String) -> [[String: Any]] {
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        return list.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return ["type": "function", "function": [
                "name": name,
                "description": t["description"] as? String ?? "",
                "parameters": t["inputSchema"] ?? ["type": "object", "properties": [:]],
            ] as [String: Any]]
        }
    }

    private static func systemPrompt(_ instructions: String) -> String {
        """
        You are the design agent inside Nurby, a parametric CAD app on iPad and iPhone. The person \
        sees the 3D model update live beside this chat and reads your replies on a small panel, so keep \
        replies short: say what you built or changed and the key dimensions, no long plans.

        You model with SolidCraft's tools below, in an in-process headless session (no window; \
        the `screenshot` tool renders with the CPU). Lengths are millimetres. Make important \
        dimensions parameters so the person can change them later. Prefer `batch` for several steps. \
        Check your work with `inspect_design` or `measure` before saying it is done. Nurby saves the design \
        after every change by itself: don't call `save`, `new_design` or `open` unless the person asks for \
        another design. Files can only be read and written under the app's Documents folder: \
        \(DesignModel.filesDir.path) (designs in Designs/, exports in Exports/, imported files in Imports/).

        SolidCraft's own instructions for agents:

        \(instructions)
        """
    }
}
