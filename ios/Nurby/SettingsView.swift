import SwiftUI

/// Where the agent runs (Claude API or OpenRouter), that provider's key (Keychain) and its model.
struct SettingsView: View {
    @Bindable var agent: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var status: String?
    @State private var checking = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $agent.provider) {
                        ForEach(Provider.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(agent.provider == .anthropic
                         ? "Claude models, straight from Anthropic, billed to your Claude Console account."
                         : "Any model that can call tools, billed to your OpenRouter account.")
                }

                Section {
                    SecureField(agent.provider.keyPlaceholder, text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(save)
                    HStack {
                        Button("Save key", action: save).disabled(key.isEmpty || checking)
                        Spacer()
                        if checking { ProgressView() } else if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if agent.hasKey {
                        Button("Remove key", role: .destructive) { agent.apiKey = nil; key = ""; status = nil }
                    }
                } header: {
                    Text(agent.provider.keyName)
                } footer: {
                    Text("Stored in this device's Keychain and sent only to \(agent.provider.host). Get one at [\(agent.provider.keysLabel)](\(agent.provider.keysURL.absoluteString)).")
                }

                Section {
                    if agent.provider == .anthropic && !agent.hasKey {
                        Text("Add a key to see the Claude models it can use.").foregroundStyle(.secondary).font(.footnote)
                    } else if agent.models.isEmpty && agent.modelError == nil {
                        HStack { ProgressView(); Text("Loading models…").foregroundStyle(.secondary) }
                    }
                    if let e = agent.modelError { Text(e).foregroundStyle(.red).font(.footnote) }
                    ForEach(filtered) { m in
                        Button { agent.model = m.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).foregroundStyle(.primary)
                                    Text(m.id).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if agent.model == m.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } header: {
                    Text(agent.model.isEmpty ? "Model" : "Model · \(agent.model)")
                } footer: {
                    if agent.provider == .openRouter {
                        Text("Only models that can call tools are listed; the agent needs tools to build geometry.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: agent.provider) {
                key = ""
                status = agent.hasKey ? "Key saved" : nil
                await agent.loadModels()
            }
        }
    }

    private var filtered: [ModelInfo] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? agent.models : agent.models.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
        let sorted = list.filter { $0.id == agent.model } + list.filter { $0.id != agent.model }
        return Array(sorted.prefix(200))
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        let provider = agent.provider
        checking = true
        Task {
            do {
                let result = provider == .anthropic ? try await Anthropic.checkKey(k) : try await OpenRouter.checkKey(k)
                guard provider == agent.provider else { checking = false; return }
                status = result
                agent.apiKey = k
                key = ""
                await agent.loadModels(force: true)
            } catch {
                status = error.localizedDescription
            }
            checking = false
        }
    }
}
