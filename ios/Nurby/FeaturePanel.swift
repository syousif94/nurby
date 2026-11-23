import SwiftUI
import simd

/// One feature's inputs, inside the sidebar's editor panel (which draws the glass). Values are
/// SolidCraft expressions ("12", "plate_t * 2", "5 mm"). Creates a feature, or (with `editing`)
/// changes one.
///
/// - Extrude: everything SolidCraft's extent takes: operation, one side / flipped / symmetric /
///   two sides, end at a distance / through all / to a face (+ offset), start at the sketch
///   plane / an offset / a face, taper, and a thin wall. Faces are picked into their slot by
///   tapping "Pick" and then a face in the viewport, and cleared with ✕.
/// - Fillet / chamfer: edges as points (seeded from the selection, or the stored ones when editing),
///   listed with ✕; tapping an edge adds it. Both preview live; values that don't build turn the field red.
///
/// Live preview: an edit (and a new extrude or revolve) shows its values in the view as they are
/// typed (`DesignModel.preview`, from a checkpoint taken when the panel opened). Cancel goes back
/// to the checkpoint; Apply goes back and applies once, so it is one undo step.
/// - Shell: the selected faces (the open sides), listed the same way.
/// - Extrude profiles: the sketch's regions show on its plane in the view (`DesignModel.regionPick`);
///   tapping one there or in the list picks it (`solid.extrude {profiles: [index], exact_regions}`),
///   so overlapping shapes can be extruded piece by piece. None picked: the sketch's default.
struct FeaturePanel: View {
    let kind: FeatureKind
    let design: DesignModel
    var editing: DesignModel.Feature? = nil
    var close: () -> Void

    typealias Options = DesignModel.ExtrudeOptions
    enum Slot { case toFace, fromFace }

    @State private var value = ""
    @State private var operation: DesignModel.Operation = .join
    @State private var axis = "y"
    @State private var ext = Options()
    @State private var original: Options?
    /// Extent / thin field → the parameter (`dN`) its expression lives in, when editing.
    @State private var params: [String: String] = [:]
    @State private var picking: Slot?
    @State private var busy = false
    @State private var failure: String?
    @State private var definition: DesignModel.Definition?
    @State private var values: [String: String] = [:]
    /// A fillet's or chamfer's edges, as points on them (what the engine takes and stores). The
    /// panel holds them, not the selection, since each live preview rebuilds the model and clears it.
    @State private var edgePoints: [SIMD3<Double>] = []
    /// Features there before the panel opened: the one a new fillet's preview adds is the other one.
    @State private var baseIDs: Set<String> = []
    @State private var previewTask: Task<Void, Never>?
    /// The step's name, edited in the title (empty for a new one = SolidCraft's default name).
    @State private var name = ""
    @FocusState private var naming: Bool

    private var isEdit: Bool { editing != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                title
                if (isEdit || roundsEdges) && !design.affected.isEmpty {
                    Label("Faces this \(kind.rawValue.lowercased()) makes are tinted blue.", systemImage: "circle.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                        .labelStyle(TintedDotLabel())
                }
                if design.previewing {
                    Label("Live preview: changes show in the view as you type.", systemImage: "eye")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if isEdit && definition == nil && failure == nil {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if kind == .extrude {
                    extrudeForm
                } else {
                    simpleForm
                }

                if kind != .extrude {
                    // Values that don't build turn their fields red (see `invalid`); only a
                    // feature that couldn't be read says so.
                    if isEdit && definition == nil, let failure { Text(failure).font(.caption).foregroundStyle(Theme.conflict).lineLimit(4) }
                }
                else if let failure { Text(failure).font(.caption).foregroundStyle(Theme.conflict).lineLimit(4) }
                else if let e = design.previewError { Text(e).font(.caption).foregroundStyle(Theme.conflict).lineLimit(4) }
                else if let editing, design.previewing, let f = design.features.first(where: { $0.id == editing.id }), f.failed {
                    // The edit went in, but the feature doesn't build with these values.
                    Text(f.detail.isEmpty ? "These values don't build." : "These values don't build: \(f.detail)")
                        .font(.caption).foregroundStyle(Theme.conflict).lineLimit(4)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The form scrolls under the header, blurred by the scroll edge effect.
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: design.selection) { old, new in
            takePick(old: old, new: new)
            takeEdges(old: old, new: new)
        }
        .onChange(of: ext) { schedulePreview(); selectSlotFaces() }
        .onChange(of: design.regionPick?.chosen) { _, chosen in
            if kind == .extrude, let chosen, chosen != ext.profiles { ext.profiles = chosen }
        }
        .onChange(of: picking) { _, slot in design.regionPick?.tappable = slot == nil }
        .onChange(of: design.revision) { selectSlotFaces(); focusNewFeature() }
        .onChange(of: operation) { schedulePreview() }
        .onChange(of: values) { schedulePreview() }
        .onChange(of: value) { schedulePreview() }
        .onChange(of: axis) { schedulePreview() }
        .onDisappear {
            previewTask?.cancel()
            design.regionPick = nil
            Task { await design.endPreview(); await design.focus(nil) }
        }
        .task { await load() }
    }

    /// The step's icon and name; the name is a field, so the step is renamed right here (on
    /// Apply / Update, with the change).
    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: DrawerView.symbol(for: kind.rawValue))
                .font(.title3.weight(.semibold)).frame(width: 28)
            TextField(kind.rawValue, text: $name)
                .font(.title3.weight(.semibold))
                .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                .submitLabel(.done)
                .focused($naming)
                .fixedSize(horizontal: !naming, vertical: false)
                .accessibilityLabel("Name")
            if !naming {
                Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .onTapGesture { naming = true }
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
        }
    }

    /// The name to give the step, if the title was changed.
    private var newName: String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != editing?.name else { return nil }
        return n
    }

    /// Back on the left, Cancel and Apply/Update across from it; pinned above the form.
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: cancel) {
                Label("Features", systemImage: "chevron.left").font(.body.weight(.medium))
            }
            .tint(Theme.accent)
            .accessibilityLabel("Back to features")
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36).background(Color.primary.opacity(0.06), in: .circle)
            }
            .tint(.primary)
            .accessibilityLabel("Cancel")
            Button(action: apply) {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(busy || !ready || needsPick ? Color.secondary.opacity(0.5) : Theme.accent, in: .circle)
            }
            .disabled(busy || !ready || needsPick)
            .accessibilityLabel(isEdit ? "Update" : "Apply")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Revolve, fillet, chamfer, shell

    @ViewBuilder private var simpleForm: some View {
        if let definition {
            ForEach(definition.inputs) { input in
                field(input.label, text: Binding(get: { values[input.param] ?? "" }, set: { values[input.param] = $0 }),
                      placeholder: input.unit.isEmpty ? "value" : input.unit, invalid: invalid)
            }
        } else {
            field(fieldLabel, text: $value, placeholder: kind == .revolve ? "360 deg" : "mm or expression", invalid: invalid)
        }
        switch kind {
        case .revolve:
            operationPicker
            if !isEdit {
                Picker("Axis", selection: $axis) { Text("Sketch X axis").tag("x"); Text("Sketch Y axis").tag("y") }.pickerStyle(.segmented)
            }
        case .fillet, .chamfer:
            section("Edges")
            VStack(spacing: 4) {
                ForEach(Array(edgePoints.enumerated()), id: \.offset) { i, p in
                    StoredEdgeRow(point: p) {
                        edgePoints.remove(at: i)
                        schedulePreview(now: true)
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: edgePoints.count)
            Text(edgePoints.isEmpty ? "Tap the edges to \(kind.rawValue.lowercased()) in the viewport." : "Tap more edges to add them, or ✕ to remove one.")
                .font(.footnote).foregroundStyle(edgePoints.isEmpty ? Theme.conflict : .secondary)
        case .shell:
            if !isEdit {
                section("Open faces")
                PickList(design: design, kind: .face)
                Text(faces == 0 ? "Tap the face(s) to remove (the open side)." : "Walls go inward. Tap more faces, or ✕ to remove one.")
                    .font(.footnote).foregroundStyle(faces == 0 ? Theme.conflict : .secondary)
            }
        case .extrude:
            EmptyView()
        }
    }

    // MARK: Extrude

    @ViewBuilder private var extrudeForm: some View {
        operationPicker
        if !isEdit && sketchNames.count > 1 {
            menu("Sketch", Binding(get: { ext.sketch ?? sketchNames.last ?? "" }, set: { chooseSketch($0) }), sketchNames, \.self)
        }
        profilesSection

        // What else is picked in the view (the slot faces below show selected too, in their slots).
        if design.selection.contains(where: { !inSlot($0) }) {
            HStack {
                section("Selected")
                Spacer()
                Button("Clear") { Task { await design.select(design.selection.filter(inSlot)) } }
                    .font(.footnote.weight(.semibold)).tint(Theme.accent)
            }
            PickList(design: design, exclude: inSlot)
        }

        menu("Direction", $ext.sides, Options.Sides.allCases, \.label)
        menu("End", $ext.end, Options.End.allCases, \.label)
        switch ext.end {
        case .distance: field(ext.sides == .symmetric ? "Total" : "Distance", text: $ext.distance)
        case .throughAll: EmptyView()
        case .toFace:
            faceSlot(.toFace, point: ext.toFace, empty: "Face to extrude to")
            field("Offset", text: $ext.toOffset, placeholder: "0 (past the face)")
        }
        if ext.sides == .two {
            field("Side 2", text: $ext.distance2)
        }

        menu("Start", $ext.start, Options.Start.allCases, \.label)
        switch ext.start {
        case .sketch: EmptyView()
        case .offset: field("Offset", text: $ext.startOffset)
        case .fromFace: faceSlot(.fromFace, point: ext.fromFace, empty: "Face to start from")
        }

        section("Shape")
        field("Taper", text: $ext.taper, placeholder: "none, e.g. 5 deg")
        Toggle("Thin wall", isOn: $ext.thin.animation(.snappy))
            .font(.subheadline)
            .disabled(isEdit && original?.thin == false)
        if isEdit && original?.thin == false {
            Text("A thin wall can be chosen when the extrude is made.").font(.caption).foregroundStyle(.secondary)
        }
        if ext.thin {
            field("Thickness", text: $ext.thickness)
            menu("Wall side", $ext.thinSide, Options.ThinSide.allCases, \.label)
            if ext.thinSide == .two_sides { field("Outside", text: $ext.thickness2) }
        }
        if let missing = ext.missing {
            Text(missing).font(.footnote).foregroundStyle(Theme.conflict)
        }
    }

    // MARK: Extrude profiles

    /// Sketches an extrude can use: those built now (before the rollback bar).
    private var sketchNames: [String] { design.features.filter { $0.isSketch && !$0.rolledBack }.map(\.name) }

    private func chooseSketch(_ name: String) {
        guard name != ext.sketch else { return }
        ext.profiles = []
        ext.sketch = name
        Task { await design.loadRegions(sketch: name) }
    }

    /// The sketch's regions: tap to pick (also in the view, where they are drawn on its plane).
    @ViewBuilder private var profilesSection: some View {
        if let pick = design.regionPick, !pick.regions.isEmpty {
            HStack {
                section("Profiles")
                Spacer()
                if !pick.chosen.isEmpty {
                    Button("Use all") { design.regionPick?.chosen = [] }
                        .font(.footnote.weight(.semibold)).tint(Theme.accent)
                }
            }
            VStack(spacing: 4) {
                ForEach(pick.regions.prefix(12)) { r in
                    let on = pick.chosen.contains(r.index)
                    Button { design.toggleRegion(r.index) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16)).foregroundStyle(on ? Color.blue : Color.cyan)
                            Text("Region \(r.index + 1)").font(.subheadline.weight(.medium))
                            Spacer(minLength: 4)
                            Text(String(format: "%.0f mm²", r.area)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).frame(minHeight: 34).contentShape(.rect)
                        .background(on ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05),
                                    in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
                    }
                    .tint(.primary)
                    .accessibilityValue(on ? "Picked" : "Not picked")
                }
            }
            Text(ext.thin ? "A thin wall follows the sketch's curves, not its regions."
                 : pick.chosen.isEmpty ? "Tap regions in the view or here to extrude only those. None picked: the whole sketch."
                 : pick.regions.count > 12 ? "\(pick.chosen.count) of \(pick.regions.count) regions picked (tap more in the view)."
                 : "\(pick.chosen.count) of \(pick.regions.count) regions picked.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// A face slot: the picked face with ✕, or a button that arms picking it in the viewport.
    @ViewBuilder private func faceSlot(_ slot: Slot, point: SIMD3<Double>?, empty: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.fill").font(.system(size: 10, weight: .bold))
                .foregroundStyle(point == nil ? Color.secondary : Theme.selected).frame(width: 16)
            if let p = point {
                Text(String(format: "Face at %.1f, %.1f, %.1f", p.x, p.y, p.z)).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Button { set(slot, nil) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.hierarchical)
                        .frame(width: 30, height: 30).contentShape(.rect)
                }
                .tint(.secondary)
                .accessibilityLabel("Remove face")
            } else {
                Text(picking == slot ? "Tap a face in the view…" : empty)
                    .font(.subheadline).foregroundStyle(picking == slot ? Theme.accent : .secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(picking == slot ? "Cancel" : "Pick") {
                    if picking == slot { picking = nil } else {
                        picking = slot
                        Task { await design.toggle(nil) }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
                .padding(.trailing, 6)
            }
        }
        .padding(.leading, 8)
        .frame(minHeight: 34)
        .background((point == nil ? Color.primary.opacity(0.05) : Theme.selected.opacity(0.1)),
                    in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
        .overlay {
            if picking == slot {
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
    }

    private func set(_ slot: Slot, _ p: SIMD3<Double>?) {
        switch slot {
        case .toFace: ext.toFace = p
        case .fromFace: ext.fromFace = p
        }
    }

    /// While a slot is armed, the next face tapped goes into it (and out of the selection).
    private func takePick(old: [DesignModel.Pick], new: [DesignModel.Pick]) {
        guard let slot = picking, let face = new.first(where: { $0.kind == .face && !old.contains($0) }) else { return }
        set(slot, SIMD3(Double(face.point.x), Double(face.point.y), Double(face.point.z)))
        picking = nil
    }

    // MARK: Pieces

    private var operationPicker: some View {
        menu("Operation", $operation, DesignModel.Operation.allCases, \.label)
    }

    /// A choice as one row: its name on the left, the current option as a pop-up menu on the right.
    private func menu<T: Hashable>(_ title: String, _ selection: Binding<T>, _ options: [T], _ label: KeyPath<T, String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0[keyPath: label]).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .fixedSize()   // the option on one line
        }
        .padding(.leading, 12).padding(.trailing, 2)
        .frame(minHeight: 40)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.top, 2)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "mm or expression", invalid: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(invalid ? Theme.conflict : .secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder).font(.body.monospaced())
                .foregroundStyle(invalid ? Theme.conflict : .primary)
                .overlay {
                    if invalid {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.conflict, lineWidth: 1.5)
                    }
                }
                .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                .onSubmit(apply)
        }
        .animation(.easeOut(duration: 0.15), value: invalid)
    }

    /// The values don't build (the preview or Apply failed, or the edited feature fails).
    private var invalid: Bool {
        if isEdit && definition == nil { return false }
        if failure != nil || design.previewError != nil { return true }
        if let editing, design.previewing, let f = design.features.first(where: { $0.id == editing.id }) { return f.failed }
        return false
    }

    /// Fillet or chamfer: works on edges the panel lists.
    private var roundsEdges: Bool { kind == .fillet || kind == .chamfer }

    private var fieldLabel: String {
        switch kind { case .extrude: "Distance"; case .revolve: "Angle"; case .fillet: "Radius"; case .chamfer: "Distance"; case .shell: "Thickness" }
    }
    private var faces: Int { design.selection.filter { $0.kind == .face }.count }

    private var ready: Bool {
        if kind == .extrude { return (!isEdit || definition != nil) && ext.missing == nil }
        if isEdit { return definition != nil && values.values.allSatisfy { !Options.blank($0) } }
        return !Options.blank(value)
    }

    private var needsPick: Bool {
        switch kind {
        case .fillet, .chamfer: edgePoints.isEmpty
        case .shell: !isEdit && faces == 0
        default: false
        }
    }

    // MARK: Load / apply

    private func load() async {
        name = editing?.name ?? ""
        guard let editing else {
            switch kind {
            case .extrude: break
            case .revolve: value = "360 deg"
            case .fillet: value = "2"
            case .chamfer: value = "1"
            case .shell: value = "2"
            }
            // A fillet or chamfer starts on the selected edges, held as points (the preview clears
            // the selection); a shell works on the selection, which a rebuilt preview would clear.
            baseIDs = Set(design.features.map(\.id))
            if kind == .extrude, let last = sketchNames.last {
                ext.sketch = last
                await design.loadRegions(sketch: last)
            }
            if roundsEdges {
                edgePoints = design.selection.filter { $0.kind == .edge }.map { SIMD3(Double($0.point.x), Double($0.point.y), Double($0.point.z)) }
            }
            if kind != .shell {
                await design.beginPreview()
                schedulePreview(now: true)
            }
            return
        }
        guard let d = await design.definition(of: editing) else { failure = "Couldn't read \(editing.name)."; return }
        for i in d.inputs { values[i.param] = i.expression }
        operation = .init(stored: d.operation)
        if kind == .extrude {
            var (o, p) = Self.options(from: d)
            o.operation = operation
            if let sketch = d.raw["sketch"] as? Int, let pick = await design.loadRegions(sketch: sketch) {
                o.profiles = pick.indices(stored: d.raw["profiles"])
                design.regionPick?.chosen = o.profiles
            }
            ext = o
            original = o
            params = p
        }
        edgePoints = d.edges
        definition = d
        await design.focus(editing)
        await design.beginPreview()
        selectSlotFaces()
    }

    /// An extrude's to / from faces, selected in the view (again after each preview rebuild,
    /// which clears the selection).
    private func selectSlotFaces() {
        guard kind == .extrude else { return }
        let pts = slotFaces
        guard !pts.isEmpty else { return }
        Task { await design.selectFaces(at: pts) }
    }

    private var slotFaces: [SIMD3<Double>] {
        [ext.end == .toFace ? ext.toFace : nil, ext.start == .fromFace ? ext.fromFace : nil].compactMap { $0 }
    }

    /// A pick that is one of the slot faces (shown in its slot, not again under Selected).
    private func inSlot(_ p: DesignModel.Pick) -> Bool {
        p.kind == .face && slotFaces.contains { simd_distance(SIMD3(Float($0.x), Float($0.y), Float($0.z)), p.point) < 1e-3 }
    }

    /// Edges tapped in the view join the fillet's list (the selection is only the way in: it is
    /// cleared again, and every preview rebuild would clear it anyway).
    private func takeEdges(old: [DesignModel.Pick], new: [DesignModel.Pick]) {
        guard roundsEdges, !new.isEmpty else { return }
        var changed = false
        for e in new where e.kind == .edge && !old.contains(e) {
            let p = SIMD3(Double(e.point.x), Double(e.point.y), Double(e.point.z))
            if let i = edgePoints.firstIndex(where: { simd_distance($0, p) < 0.5 }) { edgePoints.remove(at: i) } else { edgePoints.append(p) }
            changed = true
        }
        Task { await design.select([]) }
        if changed { schedulePreview(now: true) }
    }

    /// Tint the faces a new fillet's preview makes (an edit's are tinted from the start).
    private func focusNewFeature() {
        guard roundsEdges, !isEdit, design.previewing else { return }
        let made = design.features.last { !baseIDs.contains($0.id) }
        guard made?.id != design.focusFeature?.id else { return }
        Task { await design.focus(made) }
    }

    /// Show the panel's values in the view, a moment after the last change.
    private func schedulePreview(now: Bool = false) {
        guard design.previewing, !busy else { return }
        if !isEdit || definition != nil { failure = nil }
        previewTask?.cancel()
        previewTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            if let change = previewChange() { await design.preview(change) } else { await design.previewOriginal() }
        }
    }

    /// The engine commands that make the panel's current values, or nil while they are incomplete.
    private func previewChange() -> (() async -> String?)? {
        guard ready, !needsPick else { return nil }
        let design = design
        if let editing, let definition {
            let (inputs, set) = editChanges(definition)
            if inputs.isEmpty && set.isEmpty { return nil }
            return { await design.applyEdit(editing, inputs: inputs, set: set) }
        }
        var o = ext
        o.operation = operation
        switch kind {
        case .extrude: return { await design.previewCommand("solid.extrude", o.params) }
        case .revolve:
            let p: [String: Any] = ["angle": value, "axis": axis, "operation": operation.rawValue]
            return { await design.previewCommand("solid.revolve", p) }
        case .fillet, .chamfer:
            let (command, p) = roundCommand
            return { await design.previewCommand(command, p) }
        default: return nil
        }
    }

    /// What changes an edited feature from its stored definition to the panel's values.
    private func editChanges(_ definition: DesignModel.Definition) -> (inputs: [String: String], set: [String: Any]) {
        if kind == .extrude, let original {
            var o = ext
            o.operation = operation
            return Self.changes(from: original, to: o, params: params, definition: definition)
        }
        let changed = definition.inputs.reduce(into: [String: String]()) { out, i in
            if let v = values[i.param], v != i.expression { out[i.param] = v }
        }
        var set: [String: Any] = [:]
        if kind == .revolve, operation.stored != definition.operation { set["operation"] = operation.stored }
        if kind == .fillet || kind == .chamfer {
            let pts = edgePoints
            if Set(pts.map { [$0.x, $0.y, $0.z] }) != Set(definition.edges.map { [$0.x, $0.y, $0.z] }) {
                set["edges"] = pts.map { [$0.x, $0.y, $0.z] }
            }
        }
        return (changed, set)
    }

    private func cancel() {
        picking = nil
        previewTask?.cancel()
        Task { await design.endPreview() }
        close()
    }

    private func apply() {
        guard ready, !needsPick, !busy else { return }
        busy = true
        previewTask?.cancel()
        let round = roundCommand
        let edit = editing.flatMap { f in definition.map { (f, editChanges($0)) } }
        var o = ext
        o.operation = operation
        let (kind, value, axis, operation, design, newName, baseIDs) = (kind, value, axis, operation, design, newName, baseIDs)
        Task {
            // Back to the design as the panel found it, then the change once (one undo step).
            let ok = await design.endPreview {
                var ok = true
                if let e = edit {
                    if !(e.1.inputs.isEmpty && e.1.set.isEmpty) { ok = await design.edit(e.0, inputs: e.1.inputs, set: e.1.set) }
                } else {
                    switch kind {
                    case .extrude: ok = await design.extrude(o)
                    case .revolve: ok = await design.revolve(angle: value, axis: axis, operation: operation)
                    case .fillet, .chamfer: ok = await design.run(round.0, round.1)
                    case .shell: ok = await design.shell(thickness: value)
                    }
                }
                // Then the new name, on the edited step or the one just made.
                if ok, let newName, let f = edit?.0 ?? design.features.last(where: { !baseIDs.contains($0.id) }) {
                    await design.renameFeature(f, to: newName)
                }
                return ok
            }
            busy = false
            if ok { close() } else { failure = design.error }
        }
    }

    /// A new fillet or chamfer on the panel's edges.
    private var roundCommand: (String, [String: Any]) {
        let edges = edgePoints.map { [$0.x, $0.y, $0.z] }
        return kind == .chamfer ? ("solid.chamfer", ["edges": edges, "distance": value])
                                : ("solid.fillet", ["edges": edges, "radius": value])
    }

    // MARK: Extrude definition ↔ options

    /// The extent and thin fields that hold expressions.
    private static let extentExprs = ["distance", "distance2", "start_offset", "taper", "to_offset"]
    private static let thinExprs = ["thickness", "thickness2"]

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    private static func point(_ v: Any?) -> SIMD3<Double>? {
        if let a = v as? [Double], a.count == 3 { return SIMD3(a[0], a[1], a[2]) }
        if let d = v as? [String: Any] {
            if let p = point(d["point"] ?? d["face"]) { return p }
            if let x = d["x"] as? Double, let y = d["y"] as? Double, let z = d["z"] as? Double { return SIMD3(x, y, z) }
        }
        return nil
    }

    /// An extrude's stored definition as panel options, and which parameter each expression
    /// field lives in (`timeline.inspect` puts each one in a `dN` input).
    static func options(from d: DesignModel.Definition) -> (Options, [String: String]) {
        let extent = d.raw["extent"] as? [String: Any] ?? [:]
        let thin = d.raw["thin"] as? [String: Any]
        var params: [String: String] = [:]
        func expr(_ obj: [String: Any]?, _ key: String, label: String) -> String? {
            guard let raw = string(obj?[key]) else { return nil }
            if let input = d.inputs.first(where: { $0.param == raw }) ?? d.inputs.first(where: { $0.label.lowercased() == label }) {
                params[key] = input.param
                return input.expression
            }
            return raw
        }
        var o = Options()
        o.distance = expr(extent, "distance", label: "distance") ?? o.distance
        switch (extent["direction"] as? String)?.lowercased() {
        case "negative", "reverse", "flip": o.sides = .flipped
        case "symmetric": o.sides = .symmetric
        default: o.sides = .one
        }
        if let d2 = expr(extent, "distance2", label: "distance 2") { o.distance2 = d2; if o.sides == .one { o.sides = .two } }
        if extent["through_all"] as? Bool == true { o.end = .throughAll }
        if let to = point(extent["to"]) { o.end = .toFace; o.toFace = to }
        o.toOffset = expr(extent, "to_offset", label: "to offset") ?? ""
        if let s = expr(extent, "start_offset", label: "start offset") { o.start = .offset; o.startOffset = s }
        if let from = point(extent["from"]) { o.start = .fromFace; o.fromFace = from }
        o.taper = expr(extent, "taper", label: "taper angle") ?? ""
        if let thin {
            o.thin = true
            o.thickness = expr(thin, "thickness", label: "thickness") ?? o.thickness
            o.thinSide = Options.ThinSide(rawValue: (thin["side"] as? String) ?? "center") ?? .center
            o.thickness2 = expr(thin, "thickness2", label: "thickness 2") ?? o.thickness2
        }
        return (o, params)
    }

    /// What `DesignModel.edit` needs to turn `a` into `b`: changed expressions that live in a
    /// parameter go through `parameters.change`; the rest (and structure) through `timeline.edit`.
    static func changes(from a: Options, to b: Options, params: [String: String], definition: DesignModel.Definition)
        -> (inputs: [String: String], set: [String: Any]) {
        var inputs: [String: String] = [:]
        var extent: [String: Any] = [:]
        var thin: [String: Any] = [:]
        var set: [String: Any] = [:]

        /// An expression field that is `on` in `b` with value `new` (was `old`, `wasOn`).
        func expr(_ key: String, on: Bool, wasOn: Bool, old: String, new: String, into obj: inout [String: Any], required: Bool = false) {
            let new = new.trimmingCharacters(in: .whitespaces)
            if on && !new.isEmpty {
                guard !wasOn || new != old else { return }
                if wasOn, let param = params[key] { inputs[param] = new } else { obj[key] = new }
            } else if wasOn && !required {
                obj[key] = NSNull()
            }
        }

        if b.operation != a.operation { set["operation"] = b.operation.stored }
        if b.profiles != a.profiles {
            set["profiles"] = b.profiles.isEmpty ? ["type": "all"] as [String: Any] : ["type": "indices", "indices": b.profiles.sorted()]
        }
        if b.sides.direction != a.sides.direction { extent["direction"] = b.sides.direction }
        expr("distance", on: b.end == .distance, wasOn: true, old: a.distance, new: b.distance, into: &extent, required: true)
        expr("distance2", on: b.sides == .two, wasOn: a.sides == .two, old: a.distance2, new: b.distance2, into: &extent)
        if (b.end == .throughAll) != (a.end == .throughAll) { extent["through_all"] = b.end == .throughAll }
        let to = b.end == .toFace ? b.toFace : nil, oldTo = a.end == .toFace ? a.toFace : nil
        if to != oldTo { extent["to"] = to.map { [$0.x, $0.y, $0.z] as Any } ?? NSNull() }
        expr("to_offset", on: b.end == .toFace, wasOn: a.end == .toFace && !Options.blank(a.toOffset), old: a.toOffset, new: b.toOffset, into: &extent)
        expr("start_offset", on: b.start == .offset, wasOn: a.start == .offset, old: a.startOffset, new: b.startOffset, into: &extent)
        let from = b.start == .fromFace ? b.fromFace : nil, oldFrom = a.start == .fromFace ? a.fromFace : nil
        if from != oldFrom { extent["from"] = from.map { [$0.x, $0.y, $0.z] as Any } ?? NSNull() }
        expr("taper", on: true, wasOn: !Options.blank(a.taper), old: a.taper, new: b.taper, into: &extent)

        if a.thin && !b.thin {
            set["thin"] = NSNull()
        } else if b.thin {
            expr("thickness", on: true, wasOn: true, old: a.thickness, new: b.thickness, into: &thin, required: true)
            if b.thinSide != a.thinSide { thin["side"] = b.thinSide.rawValue }
            expr("thickness2", on: b.thinSide == .two_sides, wasOn: a.thinSide == .two_sides, old: a.thickness2, new: b.thickness2, into: &thin)
            if !thin.isEmpty { set["thin"] = thin }
        }
        if !extent.isEmpty { set["extent"] = extent }
        return (inputs, set)
    }
}

/// A small blue dot before the text (the colour of the affected-faces tint).
private struct TintedDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Color.blue.opacity(0.5)).frame(width: 9, height: 9)
            configuration.title
        }
    }
}

/// A fillet's or chamfer's stored edge, shown like a picked edge but without ✕ (they change
/// through "Change edges").
private struct StoredEdgeRow: View {
    let point: SIMD3<Double>
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.diagonal").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.selection(.edge)).frame(width: 16)
            Text(String(format: "Edge at %.1f, %.1f, %.1f", point.x, point.y, point.z))
                .font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.hierarchical)
                        .frame(width: 30, height: 30).contentShape(.rect)
                }
                .tint(.secondary)
                .accessibilityLabel("Remove edge")
            }
        }
        .padding(.leading, 8).padding(.trailing, remove == nil ? 8 : 0)
        .frame(minHeight: 34)
        .background(Theme.selection(.edge).opacity(0.1), in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
    }
}
