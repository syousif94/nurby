import SwiftUI
import UniformTypeIdentifiers

/// Nurby's home: describe a part to start a new design with the agent, start an empty one,
/// import a CAD file, or pick up a recent design.
struct StartView: View {
    let design: DesignModel
    @Bindable var agent: AgentSession
    var open: () -> Void
    var openSettings: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var designs: [DesignModel.SavedDesign] = []
    @State private var prompt = ""
    @State private var importing = false
    @State private var deleting: DesignModel.SavedDesign?
    @State private var busy = false
    @State private var renaming: DesignModel.SavedDesign?
    @State private var newName = ""
    @FocusState private var promptFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.ground(scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    promptCard
                    actions
                    recents
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            if busy { ProgressView().controlSize(.large).padding(24).glassEffect(in: .rect(cornerRadius: 20)) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            run { await design.importFile(url) }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { Task { await design.delete(d.url); reload() } }
                deleting = nil
            }
        } message: {
            Text("The design file is removed from this device. This can't be undone.")
        }
        .alert("Rename design", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let d = renaming { let name = newName; Task { await design.rename(d, to: name); reload() } }
                renaming = nil
            }
        }
        .onAppear(perform: reload)
        .task { await design.seedDemoIfNeeded(); reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nurby").font(.largeTitle.weight(.bold))
                Text("Parametric CAD you can talk to").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .tint(.primary)
            .accessibilityLabel("Settings")
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Start with the agent", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.agent)
            TextField("Describe a part — “a 90 × 60 mm plate, 4 mm thick, with M3 holes in the corners”", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .focused($promptFocused)
                .onSubmit(startWithPrompt)
            HStack {
                if !agent.hasKey {
                    Button("Add a key", action: openSettings).font(.footnote)
                } else {
                    Text(agent.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: startWithPrompt) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(prompt.isEmpty ? Color.gray : Theme.accent, in: .circle)
                }
                .disabled(prompt.isEmpty)
                .accessibilityLabel("Start design")
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 26))
    }

    /// Scrolls sideways when the buttons don't fit, running to the screen edges (the page's
    /// side padding becomes the scroll's content margin, so they still line up at rest).
    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                actionButton("New design", "plus") { run { await design.newDesign() } }
                actionButton("Import file", "square.and.arrow.down") { importing = true }
                if let last = designs.first {
                    actionButton("Continue \(last.name)", "arrow.uturn.right") { openDesign(last) }
                }
            }
            .padding(.vertical, 8)   // room for the glass shadows
        }
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.horizontal, -24)
        .padding(.vertical, -8)
    }

    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16).frame(height: 44)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .tint(.primary)
    }

    @ViewBuilder private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent designs").font(.title3.weight(.semibold))
            if designs.isEmpty {
                Text("Your designs appear here. Each one saves itself as you work, and you can find them in the Files app under Nurby › Designs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(designs) { d in
                    Button { openDesign(d) } label: { DesignCard(design: d) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") { openDesign(d) }
                            Button("Rename…", systemImage: "pencil") { newName = d.name; renaming = d }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = d }
                        }
                }
            }
        }
    }

    private func reload() { designs = DesignModel.savedDesigns() }

    private func openDesign(_ d: DesignModel.SavedDesign) {
        if d.url.path == design.path { open(); return }
        run { await design.open(d.url) }
    }

    private func startWithPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard agent.hasKey else { openSettings(); return }
        prompt = ""
        run {
            await design.newDesign()
            agent.send(text, design: design)
        }
    }

    /// Do some design work, then go to the studio with a fresh chat.
    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            agent.newChat()
            await work()
            busy = false
            open()
        }
    }
}

private struct DesignCard: View {
    let design: DesignModel.SavedDesign
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.opacity(scheme == .dark ? 0.25 : 0.6))
                if let img = Thumbnails.image(for: design.url) {
                    Image(uiImage: img).resizable().scaledToFit().padding(8)
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            VStack(alignment: .leading, spacing: 2) {
                Text(design.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(design.modified, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .glassEffect(in: .rect(cornerRadius: 24))
        .contentShape(.rect)
    }
}
