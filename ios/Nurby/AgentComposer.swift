import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The agent's message box, pinned to the bottom of the studio: selection chips, attached
/// pictures, the text field, an image "+" menu (photos, files, a snapshot of the view, pen
/// markup), a model menu and send/stop.
struct AgentComposer: View {
    @Bindable var agent: AgentSession
    let design: DesignModel
    @Binding var draft: String
    @Binding var images: [UIImage]
    var focused: FocusState<Bool>.Binding
    var snapshot: () -> Void
    var markup: () -> Void
    var openSettings: () -> Void
    var didSend: () -> Void = {}

    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !design.selection.isEmpty { chips }
            if !images.isEmpty { attachments }
            TextField(design.selection.isEmpty ? "Ask, or describe a change…" : "What should change here?", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.horizontal, 10).padding(.top, 6)
                .onSubmit(send)
            HStack(spacing: 8) {
                addMenu
                modelMenu
                Spacer(minLength: 0)
                if !images.isEmpty && !agent.modelSeesImages {
                    Label("Model can't see images", systemImage: "eye.slash")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                sendButton
            }
            .tint(.primary)
        }
        .padding(8)
        .background(.background.opacity(0.55), in: .rect(cornerRadius: 26, style: .continuous))
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { images.append(img) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { images.append(img) }
            }
        }
        .task(id: agent.provider) { await agent.loadModels() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(design.selection) { p in
                    Button { Task { await design.deselect(p) } } label: {
                        Label(design.pickOrigins[p.id]?.first.map { "\(p.label) · \($0.name)" } ?? p.label, systemImage: "xmark.circle.fill")
                            .labelStyle(TrailingIconLabel())
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.selection(p.kind))
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Theme.selection(p.kind).opacity(0.15), in: .capsule)
                    }
                    .accessibilityLabel("Deselect \(p.label)")
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images.indices, id: \.self) { i in
                    Image(uiImage: images[i]).resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
                        .overlay(alignment: .topTrailing) {
                            Button { images.remove(at: i) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(.black.opacity(0.6), in: .circle)
                            }
                            .padding(4)
                            .accessibilityLabel("Remove picture")
                        }
                }
            }
            .padding(.horizontal, 4).padding(.top, 4)
        }
    }

    private var addMenu: some View {
        Menu {
            Button(action: markup) { Label("Mark up view", systemImage: "pencil.tip.crop.circle") }
            Button(action: snapshot) { Label("Snapshot of view", systemImage: "camera.viewfinder") }
            Divider()
            Button { pickingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { importing = true } label: { Label("Choose File", systemImage: "folder") }
        } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32).background(.quaternary, in: .circle)
        }
        .accessibilityLabel("Add image")
    }

    private var modelMenu: some View {
        Menu {
            let recent = agent.recentModels
            let suggested = agent.suggestedModels.filter { !recent.contains($0) }
            if !recent.isEmpty {
                Section("Recent") { ForEach(recent, id: \.self) { modelButton($0) } }
            }
            if !suggested.isEmpty {
                Section("Suggested") { ForEach(suggested, id: \.self) { modelButton($0) } }
            }
            Divider()
            Picker("Provider", selection: $agent.provider) {
                ForEach(Provider.allCases) { p in
                    Text(agent.hasKey(p) ? p.title : "\(p.title) (no key)").tag(p)
                }
            }
            .pickerStyle(.menu)
            Button(action: openSettings) { Label("All models…", systemImage: "list.bullet") }
        } label: {
            HStack(spacing: 4) {
                Text(agent.model.isEmpty ? "Choose model" : agent.displayName(agent.model)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.footnote.weight(.medium)).padding(.horizontal, 12).frame(height: 32)
            .background(.quaternary, in: .capsule)
        }
        .accessibilityLabel("Model")
    }

    private func modelButton(_ id: String) -> some View {
        Button { agent.model = id } label: {
            if id == agent.model {
                Label(agent.displayName(id), systemImage: "checkmark")
            } else if agent.info(id)?.acceptsImages == true {
                Label(agent.displayName(id), systemImage: "eye")
            } else {
                Text(agent.displayName(id))
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        if agent.busy {
            Button(action: agent.stop) {
                Image(systemName: "stop.fill").font(.system(size: 13)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Theme.conflict, in: .circle)
            }
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(canSend ? Theme.accent : Color.gray, in: .circle)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private func send() {
        guard canSend, !agent.busy else { return }
        guard agent.send(draft, images: images, design: design) else { didSend(); return }
        draft = ""
        images = []
        didSend()
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}
