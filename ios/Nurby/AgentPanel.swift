import SwiftUI

/// The agent chat: your messages in bubbles, the agent's replies as plain text, each tool call
/// as a compact row; the composer (`footer`) sits at the bottom.
struct AgentPanel<Footer: View>: View {
    @Bindable var agent: AgentSession
    let design: DesignModel
    var hide: () -> Void
    var openSettings: () -> Void
    @Binding var draft: String
    var focus: () -> Void
    /// While a sketch or feature panel is open: just the composer (or a connect button), no
    /// header or transcript, so the editor gets the height.
    var collapsed = false
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 10) {
            if collapsed {
                if agent.hasKey {
                    footer
                } else {
                    Button(action: openSettings) {
                        Label("Add an API key for the agent", systemImage: "key.horizontal")
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .tint(Theme.agent)
                }
            } else {
            header
            if !agent.hasKey {
                connect
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if agent.entries.isEmpty {
                                welcome
                                // In the scroll (bottom-anchored, so still just above the input) so
                                // a short panel scrolls them instead of overflowing.
                                recents.padding(.top, 6)
                            }
                            ForEach(agent.entries) { e in row(e).id(e.id) }
                            if agent.busy {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) }
                                    .id("busy")
                            }
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 0, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: agent.entries.count) {
                        withAnimation { proxy.scrollTo(agent.busy ? AnyHashable("busy") : AnyHashable(agent.entries.last?.id), anchor: .bottom) }
                    }
                }
                footer
            }
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: Theme.panelRadius))
    }

    /// Just the chat controls, right-aligned (no avatar or status line).
    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 4)
            if agent.hasKey {
                Menu {
                    if agent.recentChats.isEmpty { Text("No saved chats yet") }
                    ForEach(agent.recentChats.prefix(12)) { c in
                        Button { agent.open(c) } label: { Text(c.title); Text(subtitle(c)) }
                    }
                } label: { HeaderIcon(symbol: "clock.arrow.circlepath") }
                .accessibilityLabel("Chat history")
                Button(action: agent.newChat) { HeaderIcon(symbol: "square.and.pencil") }
                    .accessibilityLabel("New chat")
                    .disabled(agent.entries.isEmpty)
            }
            Button(action: openSettings) { HeaderIcon(symbol: "gearshape") }.accessibilityLabel("Settings")
        }
        .tint(.primary)
    }

    /// No key yet: what the agent is and how to connect it.
    private var connect: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Theme.agent.opacity(0.12))
                Image(systemName: "key.horizontal.fill").font(.system(size: 26)).foregroundStyle(Theme.agent)
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 6) {
                Text("Design by describing it").font(.title3.weight(.semibold))
                Text("The agent builds and edits this design with the same tools you use. It runs on Claude with your Anthropic API key, or on any tool-calling model through OpenRouter.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button(action: openSettings) {
                Label("Add an API key", systemImage: "plus")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(Theme.agent, in: .capsule)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What should we make?").font(.title3.weight(.semibold))
            Text("Describe a part or a change. Tap faces or edges first to point at them.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// Above the input on an empty chat: the last few chats to pick up, or example prompts.
    @ViewBuilder private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            if agent.recentChats.isEmpty {
                Text("Try").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(Self.examples, id: \.self) { ex in
                    Button { draft = ex; focus() } label: {
                        Text(ex).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("Recent chats").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(agent.recentChats.prefix(4)) { c in
                    Button { agent.open(c) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.subheadline).lineLimit(1)
                                Text(subtitle(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8).frame(height: 46)
                        .contentShape(.rect)
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { agent.delete(c) }
                    }
                }
            }
        }
        .tint(.primary)
    }

    private func subtitle(_ c: AgentSession.Chat) -> String {
        let when = c.updated.formatted(.relative(presentation: .named))
        return c.design.isEmpty ? when : "\(c.design) · \(when)"
    }

    static var examples: [String] { [
        "A 90 × 60 mm mounting plate, 4 mm thick, with an M3 clearance hole 5 mm in from each corner. Make the sizes parameters.",
        "A cylindrical cup, 70 mm across and 90 mm tall, with 2 mm walls and a filleted rim.",
        "A phone stand: a 80 mm wide base and a back rest leaning at 65°.",
    ] }

    @ViewBuilder private func row(_ e: AgentSession.Entry) -> some View {
        switch e.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if !e.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(e.images.indices, id: \.self) { i in
                            Image(uiImage: e.images[i]).resizable().scaledToFill()
                                .frame(width: e.images.count == 1 ? 180 : 88, height: e.images.count == 1 ? 120 : 88)
                                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
                Text(e.text).font(.subheadline)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(.quaternary, in: .rect(cornerRadius: 20))
                if let c = e.context { Text(c).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .agent:
            Text(LocalizedStringKey(e.text)).font(.subheadline).textSelection(.enabled)
        case .tool(let ok):
            Label(e.text, systemImage: ok ? "gearshape" : "exclamationmark.triangle")
                .font(.caption.monospaced())
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.conflict))
                .lineLimit(3)
        case .error:
            Label(e.text, systemImage: "exclamationmark.octagon").font(.footnote).foregroundStyle(Theme.conflict)
        }
    }
}
