import SwiftUI

enum DrawerTab: String, CaseIterable { case features = "Features", parameters = "Parameters", versions = "Versions" }

/// The drawer: design menu (new, export), undo/redo, the feature timeline and the parameters.
/// It draws no glass of its own: `StudioView.editor` holds it (or a feature panel) in one panel.
struct DrawerView: View {
    let design: DesignModel
    @Binding var tab: DrawerTab
    var hide: () -> Void
    var hideSymbol = "sidebar.right"
    var goHome: () -> Void
    var editFeature: (DesignModel.Feature) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var renaming = false
    @State private var newName = ""
    @State private var shareURL: URL?
    @State private var editing: DesignModel.Parameter?
    @State private var editText = ""
    @State private var renamingFeature: DesignModel.Feature?
    @State private var featureName = ""
    @State private var addingParameter = false
    @State private var paramName = ""
    @State private var paramExpr = ""
    /// The rollback bar while it is dragged: where it started and where it is now (rows above it).
    @State private var barStart: Int?
    @State private var barAt: Int?
    /// The bar's engine steps, one after another.
    @State private var barTask: Task<Void, Never>?
    /// The row a dragged step would land on (it takes that row's place).
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: goHome) { HeaderIcon(symbol: "house") }
                    .accessibilityLabel("Home")
                Menu {
                    Button("Rename…", systemImage: "pencil") { newName = design.name; renaming = true }.disabled(design.path == nil)
                    Button("Duplicate", systemImage: "plus.square.on.square") { Task { await design.duplicate() } }.disabled(design.path == nil)
                    if design.versions.branches.count > 1 {
                        Menu("Switch branch", systemImage: "arrow.triangle.branch") {
                            ForEach(design.versions.branches) { b in
                                Button { Task { await design.switchBranch(to: b.name) } } label: {
                                    if b.name == design.versions.branch { Label(b.name, systemImage: "checkmark") } else { Text(b.name) }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Export STEP…", systemImage: "square.and.arrow.up") { export("step") }
                    Button("Export STL…", systemImage: "square.and.arrow.up") { export("stl") }
                    Button("Export 3MF…", systemImage: "square.and.arrow.up") { export("3mf") }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(design.name).font(.headline).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            if design.path != nil {
                                Label(design.versions.branch, systemImage: "arrow.triangle.branch")
                                    .labelStyle(.titleAndIcon).font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).frame(height: 18)
                                    .background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: 7, style: .continuous))
                                    .foregroundStyle(Theme.accent)
                            }
                            if let v = design.viewingVersion {
                                Text("Viewing V\(v.number)")
                            } else {
                                Circle().fill(design.path == nil ? Color.orange : design.saving ? Color.yellow : Color.green).frame(width: 6, height: 6)
                                Text(design.path == nil ? "Not saved yet" : design.saving ? "Saving…" : "Saved")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .accessibilityLabel("Design menu")
                HStack(spacing: 0) {
                    Button { Task { await design.undo() } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 34) }
                        .accessibilityLabel("Undo")
                    Divider().frame(height: 16)
                    Button { Task { await design.redo() } } label: { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 34) }
                        .accessibilityLabel("Redo")
                }
                .font(.system(size: 15, weight: .medium))
                .background(.primary.opacity(0.07), in: .capsule)
                Button(action: hide) { HeaderIcon(symbol: hideSymbol) }
                    .accessibilityLabel("Hide panels")
            }
            .tint(.primary)

            Picker("Section", selection: $tab) {
                ForEach(DrawerTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)

            if let v = design.viewingVersion {
                HStack(spacing: 8) {
                    Image(systemName: "eye").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Viewing V\(v.number) · \(v.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("Changes here aren't saved.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Restore") { Task { await design.restore(v) } }.font(.subheadline.weight(.semibold))
                    Button("Back") { Task { await design.stopViewing() } }.font(.subheadline.weight(.semibold))
                }
                .tint(Theme.accent)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
            }

          }
          .padding([.horizontal, .top], 12)

            // The list runs to the panel's edges and up to the tabs; only its content is inset.
            ScrollView {
                Group {
                    switch tab {
                    case .features: featureList
                    case .parameters: parameterList
                    case .versions: VersionsView(design: design)
                    }
                }
                .padding(12)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let err = design.error {
                    Text(err).font(.caption).foregroundStyle(Theme.conflict).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .sheet(item: $shareURL) { ShareSheet(url: $0) }
        .alert("Rename design", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await design.rename(to: newName) } }
        }
        .alert("Change \(editing?.name ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Value or expression", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Set") {
                if let p = editing { Task { await design.setParameter(p.name, to: editText) } }
                editing = nil
            }
        } message: {
            Text("A number in mm, or an expression using other parameters.")
        }
        .alert("Rename feature", isPresented: Binding(get: { renamingFeature != nil }, set: { if !$0 { renamingFeature = nil } })) {
            TextField("Name", text: $featureName)
            Button("Cancel", role: .cancel) { renamingFeature = nil }
            Button("Rename") {
                if let f = renamingFeature { let n = featureName; Task { await design.renameFeature(f, to: n) } }
                renamingFeature = nil
            }
        }
        .alert("New parameter", isPresented: $addingParameter) {
            TextField("name (snake_case)", text: $paramName).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("value, e.g. 12 mm", text: $paramExpr).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") { let n = paramName, e = paramExpr; Task { await design.addParameter(name: n, expression: e) } }
        } message: {
            Text("Use it in any dimension or feature value by name.")
        }
    }

    private var featureList: some View {
        let origins = design.originIDs
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if design.features.isEmpty { empty("No features yet. Start a sketch from the bar below, or ask the agent to build something.") }
                ForEach(design.features) { f in
                    let origin = origins.contains(f.id)
                    let past = f.position >= shownMarker
                    HStack(spacing: 7) {
                        Image(systemName: Self.symbol(for: f.kind)).font(.system(size: 14)).frame(width: 18)
                            .foregroundStyle(f.failed ? Theme.conflict : origin ? Theme.selected : .secondary)
                        Text(f.name).font(.subheadline.weight(origin ? .semibold : .medium)).lineLimit(1)
                        Spacer()
                        Text(f.kind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .padding(.bottom, f.failed && !f.detail.isEmpty ? 30 : 0)
                    .overlay(alignment: .bottomLeading) {
                        if f.failed && !f.detail.isEmpty {
                            Text(f.detail).font(.caption2).foregroundStyle(Theme.conflict).lineLimit(2)
                                .padding(.leading, 33).padding(.trailing, 8).padding(.bottom, 4)
                        }
                    }
                    .background(origin ? Theme.selected.opacity(0.16) : .clear, in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
                    .overlay(alignment: .leading) {
                        if origin { Capsule().fill(Theme.selected).frame(width: 3, height: 18).offset(x: -2) }
                    }
                    .opacity(past ? 0.4 : 1)
                    .padding(.top, f.position == shownMarker ? Self.barHeight : 0)
                    .contentShape(.rect)
                    .id(f.id)
                    .help(f.detail)
                    .contextMenu {
                        if f.isSketch {
                            Button("Edit sketch", systemImage: "square.and.pencil") { Task { await design.editSketch(f.name) } }
                        } else if Self.editable(f) != nil {
                            Button("Edit \(f.kind.lowercased())…", systemImage: "slider.horizontal.3") { editFeature(f) }
                        }
                        if f.position + 1 != design.marker {
                            Button("Roll back to here", systemImage: "backward.end") { Task { await design.rollTo(f.position + 1) } }
                        }
                        if f.position > 0 {
                            Button("Move up", systemImage: "arrow.up") { Task { await design.reorder(f, to: f.position - 1) } }
                        }
                        if f.position + 1 < design.features.count {
                            Button("Move down", systemImage: "arrow.down") { Task { await design.reorder(f, to: f.position + 1) } }
                        }
                        Button("Rename…", systemImage: "pencil") { featureName = f.name; renamingFeature = f }
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await design.deleteFeature(f) } }
                    }
                    // Long-press and drag a step onto another row to move it there (SolidCraft
                    // refuses a move that would break a step, and the drawer says why).
                    .draggable(f.id) {
                        Label(f.name, systemImage: Self.symbol(for: f.kind))
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 34)
                            .background(.regularMaterial, in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        dropTarget = nil
                        guard let id = ids.first, let moved = design.features.first(where: { $0.id == id }), moved.id != f.id else { return false }
                        Task { await design.reorder(moved, to: f.position) }
                        return true
                    } isTargeted: { on in
                        if on { dropTarget = f.id } else if dropTarget == f.id { dropTarget = nil }
                    }
                    .overlay {
                        if dropTarget == f.id {
                            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
                        }
                    }
                    .onTapGesture {
                        if f.isSketch { Task { await design.editSketch(f.name) } } else if Self.editable(f) != nil { editFeature(f) }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if !design.features.isEmpty { rollbackBar.offset(y: barY(shownMarker)) }
            }
            .animation(.easeOut(duration: 0.2), value: origins)
            .animation(.snappy(duration: 0.2), value: shownMarker)
            .onChange(of: origins) { _, ids in
                if let first = design.features.last(where: { ids.contains($0.id) }) { withAnimation { proxy.scrollTo(first.id, anchor: .center) } }
            }
        }
    }

    // MARK: Rollback bar

    static let barHeight: CGFloat = 22
    private var shownMarker: Int { barAt ?? design.marker }

    private func rowHeight(_ f: DesignModel.Feature) -> CGFloat { 34 + (f.failed && !f.detail.isEmpty ? 30 : 0) }

    /// Top of the bar when `k` rows are above it.
    private func barY(_ k: Int) -> CGFloat { design.features.prefix(k).reduce(0) { $0 + rowHeight($1) } }

    /// The bar under the last active feature: drag its gripper up to roll the design back (the
    /// view follows as it moves, and features below it are greyed and not built), down to roll
    /// forward. New features go in at the bar. Dragging is previewed and lands as one undo step.
    private var rollbackBar: some View {
        let n = design.features.count
        return HStack(spacing: 6) {
            Capsule().fill(Theme.accent).frame(height: 2)
            if shownMarker < n {
                Button { Task { await design.rollTo(n) } } label: {
                    Text("Roll to end").font(.caption2.weight(.semibold))
                }
                .tint(Theme.accent)
                .buttonStyle(.borderless)
                .accessibilityLabel("Roll forward to the end")
            }
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .bold))
                .foregroundStyle(barAt == nil ? Color.secondary : Theme.accent)
                .frame(width: 30, height: 18)
                .background(Color.primary.opacity(barAt == nil ? 0.08 : 0.14), in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect.inset(by: -10))
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        if barStart == nil {
                            barStart = design.marker
                            barStep { await $0.beginPreview() }
                        }
                        let want = barY(barStart ?? 0) + v.translation.height
                        let k = (0...n).min { abs(barY($0) - want) < abs(barY($1) - want) } ?? n
                        if k != barAt {
                            barAt = k
                            UISelectionFeedbackGenerator().selectionChanged()
                            barStep { design in await design.preview { await design.previewCommand("timeline.roll_to", k >= n ? [:] : ["position": k]) } }
                        }
                    }
                    .onEnded { _ in
                        let k = barAt, start = barStart
                        barStep { design in
                            // Back to where it started, then one move there (one undo step).
                            let move: (() async -> Bool)? = k.flatMap { k in
                                k == start ? nil : { await design.run("timeline.roll_to", k >= n ? [:] : ["position": k]) }
                            }
                            await design.endPreview(commit: move)
                        }
                        barStep { _ in barAt = nil; barStart = nil }
                    })
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: Self.barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rollback bar")
        .accessibilityValue("After \(shownMarker) of \(n) features")
        .accessibilityAdjustableAction { dir in
            let k = dir == .increment ? min(design.marker + 1, n) : max(design.marker - 1, 0)
            Task { await design.rollTo(k) }
        }
    }

    private func barStep(_ step: @escaping @MainActor (DesignModel) async -> Void) {
        let prev = barTask, design = design
        barTask = Task { await prev?.value; await step(design) }
    }

    /// The feature panel kind that can edit this feature, if any.
    static func editable(_ f: DesignModel.Feature) -> FeatureKind? {
        FeatureKind(rawValue: f.kind.components(separatedBy: " ·").first ?? f.kind)
    }

    private var parameterList: some View {
        VStack(spacing: 0) {
            Button { paramName = ""; paramExpr = ""; addingParameter = true } label: {
                Label("Add parameter", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 34)
            }
            .tint(Theme.accent)
            if design.parameters.isEmpty { empty("No parameters yet. Parameters are named values you can use in any dimension.") }
            ForEach(design.parameters) { p in
                Button { editing = p; editText = p.expr } label: {
                    HStack(spacing: 7) {
                        Text(p.name).font(.subheadline.monospaced().weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(p.expr == p.value || p.value.isEmpty ? p.expr : "\(p.expr) = \(p.value)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 8).frame(height: 34).contentShape(.rect)
                }
                .tint(.primary)
                .contextMenu {
                    Button("Edit…", systemImage: "pencil") { editing = p; editText = p.expr }
                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await design.deleteParameter(p.name) } }
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }

    private func export(_ ext: String) {
        Task { if let url = await design.export(as: ext) { shareURL = url } }
    }

    static func symbol(for kind: String) -> String {
        let k = kind.lowercased()
        if k.contains("sketch") { return "square.and.pencil" }
        if k.contains("extrude") { return "cube" }
        if k.contains("revolve") { return "arrow.triangle.2.circlepath" }
        if k.contains("hole") { return "circle.circle" }
        if k.contains("fillet") { return "square.on.square.squareshape.controlhandles" }
        if k.contains("chamfer") { return "triangle" }
        if k.contains("shell") { return "shippingbox" }
        if k.contains("pattern") { return "square.grid.2x2" }
        if k.contains("mirror") { return "arrow.left.and.right.righttriangle.left.righttriangle.right" }
        if k.contains("plane") { return "square.stack.3d.up" }
        return "cube.transparent"
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
