import Foundation
import Observation
import simd

/// The open design as the UI sees it: the Rust `Studio` (a SolidCraft session), its display
/// meshes, and what `document.inspect` reports (features, parameters). Every change, from the
/// UI or the agent, goes through the studio; `refresh()` re-reads it afterwards.
@MainActor @Observable
final class DesignModel {
    struct Feature: Identifiable, Hashable {
        let id: String; let name: String; let kind: String; let detail: String; let failed: Bool
        /// Index in the timeline (what `timeline.roll_to {position}` takes to stop just before it).
        var position = 0
        /// Past the timeline marker (while a sketch or feature before it is being edited).
        var rolledBack = false
        var isSketch: Bool { kind.lowercased().contains("sketch") }
    }

    /// A feature's editable definition, from `timeline.inspect`.
    struct Definition {
        struct Input: Identifiable { var id: String { param }; let param: String; let label: String; let expression: String; let unit: String }
        let inputs: [Input]
        let raw: [String: Any]
        var operation: String? { raw["operation"] as? String }
        var direction: String? { (raw["extent"] as? [String: Any])?["direction"] as? String }
        var edges: [SIMD3<Double>] {
            (raw["edges"] as? [Any] ?? []).compactMap { e in
                (e as? [Double]).flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
            }
        }
    }
    struct Parameter: Identifiable, Hashable { var id: String { name }; let name: String; let expr: String; let value: String }

    /// A face or edge picked in the viewport. `point` is where it was picked, in model mm.
    struct Pick: Identifiable, Hashable {
        enum Kind: String { case face, edge }
        let kind: Kind
        let body: String
        let index: UInt32
        let point: SIMD3<Float>
        var id: String { "\(kind.rawValue) \(body) \(index)" }
        /// The same face or edge wherever it was picked: `point` is not part of its identity.
        static func == (a: Pick, b: Pick) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
        var label: String { "\(kind.rawValue.capitalized) \(index + 1) of \(body)" }
        /// How the agent is told about it: what `select.set` and other commands take.
        var context: String {
            String(format: "%@ %u of body \"%@\" (index %u, picked at [%.2f, %.2f, %.2f] mm)", kind.rawValue, index + 1, body, index, point.x, point.y, point.z)
        }
    }

    let studio: Studio
    private(set) var meshes: [BodyMesh] = []
    private(set) var features: [Feature] = []
    private(set) var parameters: [Parameter] = []
    private(set) var revision = 0
    /// The design's file, once it has one (every design with features is saved as it changes).
    private(set) var path: String?
    private(set) var saving = false
    /// What's picked in the viewport; also SolidCraft's own selection (`select.set`).
    private(set) var selection: [Pick] = []
    /// The sketch being edited, if any (SolidCraft's active sketch, from `sketch.inspect`).
    private(set) var sketch: Sketch?
    /// The regions of the sketch an extrude panel works on, shown on its plane in the viewport
    /// (tap to choose); nil when no panel is choosing profiles.
    var regionPick: RegionPick?
    /// For each pick, the features that made it (topology names like `F3:blend(F2:side:l1|…)`),
    /// keyed by pick id; and all of them together, for the drawer to highlight.
    private(set) var pickOrigins: [String: [Feature]] = [:]
    var originIDs: Set<String> { Set(pickOrigins.values.flatMap { $0.map(\.id) }) }
    private var topologyNames: [String: (faces: [String], edges: [String])] = [:]
    /// The feature being edited, and the faces it made (shown tinted blue while editing).
    private(set) var focusFeature: Feature?
    private(set) var affected: [Pick] = []
    /// True while the timeline is rolled back for editing a feature (not a sketch).
    var rolledBack: Bool { features.contains { $0.rolledBack } && sketch == nil }
    var error: String?
    /// Off while building the seeded demo, so it isn't autosaved as an extra "Design".
    private var autosave = true
    var name: String { workspacePath.map { URL(filePath: $0).deletingPathExtension().lastPathComponent } ?? "New design" }

    /// The design's versions and branches (`Versions.swift`).
    var versions = VersionIndex()
    private var versionsFor: String?
    /// A version shown in the studio instead of the workspace (nothing is saved while it is).
    var viewingVersion: VersionIndex.Version?
    /// The workspace's file while a version is shown.
    var workspace: String?
    /// The design's own file (the workspace), also while a version is shown.
    var workspacePath: String? { workspace ?? path }

    static let filesDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let designsDir = filesDir.appending(path: "Designs", directoryHint: .isDirectory)
    static let exportsDir = filesDir.appending(path: "Exports", directoryHint: .isDirectory)
    static let importsDir = filesDir.appending(path: "Imports", directoryHint: .isDirectory)
    private static let lastKey = "lastDesign"

    init() {
        for d in [Self.designsDir, Self.exportsDir, Self.importsDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        do {
            studio = try Studio(filesDir: Self.filesDir.path)
        } catch {
            fatalError("SolidCraft failed to start: \(error)")
        }
    }

    /// Reopen the design that was open last time, if it's still there.
    func restore() async {
        // Stored by file name: the app's container path changes when it's reinstalled or updated.
        if let last = UserDefaults.standard.string(forKey: Self.lastKey) {
            let url = Self.designsDir.appending(path: URL(filePath: last).lastPathComponent)
            if FileManager.default.fileExists(atPath: url.path), await open(url) { return }
        }
        await refresh()
    }

    /// Re-read meshes and the design summary (off the main thread; the kernel can take a while),
    /// then save the design if it changed.
    func refresh() async {
        let studio = studio
        let (meshes, inspect) = await Task.detached { () -> ([BodyMesh], String?) in
            ((try? studio.meshes()) ?? [], try? studio.inspectJson())
        }.value
        if !selection.isEmpty { selection = [] }   // faces and edges renumber when the model changes
        pickOrigins = [:]
        topologyNames = [:]
        self.meshes = meshes
        var dirty = false
        if let inspect, let data = inspect.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            features = Self.features(in: obj)
            parameters = Self.parameters(in: obj)
            path = obj["path"] as? String
            dirty = obj["dirty"] as? Bool ?? false
            if obj["active_sketch"] is NSNull || obj["active_sketch"] == nil {
                sketch = nil
            } else if let text = try? await Task.detached(operation: { [studio] in try studio.execute(command: "sketch.inspect", paramsJson: "{}") }).value,
                      let so = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                sketch = Sketch(so)
            }
        }
        revision += 1
        if focusFeature != nil { await computeAffected() }
        if let path = workspacePath { UserDefaults.standard.set(URL(filePath: path).lastPathComponent, forKey: Self.lastKey) }
        if workspacePath != versionsFor {
            versionsFor = workspacePath
            loadVersions()
        }
        if autosave && !previewing && viewingVersion == nil && dirty && (!features.isEmpty || path != nil) { await save() }
    }

    /// Save to the design's file, or to a new file in Designs the first time.
    func save() async {
        guard !saving, viewingVersion == nil else { return }
        saving = true
        defer { saving = false }
        let params: [String: Any] = path == nil ? ["path": Self.freeURL(base: "Design").path] : [:]
        let command = path == nil ? "file.save_as" : "file.save"
        if let e = await execute(command, params) {
            error = "Couldn't save: \(e)"
            return
        }
        if path == nil, let obj = await inspect() {
            path = obj["path"] as? String
            if let path { UserDefaults.standard.set(URL(filePath: path).lastPathComponent, forKey: Self.lastKey) }
        }
        if let path { Thumbnails.save(meshes, for: URL(filePath: path)) }
    }

    /// Run an engine command as the UI does, then refresh.
    @discardableResult
    func run(_ command: String, _ params: [String: Any] = [:]) async -> Bool {
        let result = await execute(command, params)
        error = result
        await refresh()
        return result == nil
    }

    /// Run an engine command without refreshing; returns the error, if any.
    private func execute(_ command: String, _ params: [String: Any] = [:]) async -> String? {
        let studio = studio
        let json = String(data: (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        return await Task.detached { () -> String? in
            do { _ = try studio.execute(command: command, paramsJson: json); return nil } catch { return DesignModel.message(error) }
        }.value
    }

    /// The engine's own words for an error, without the binding's wrapper or the
    /// "invalid parameters for `command`:" prefix.
    nonisolated static func message(_ error: Error) -> String {
        var text = "\(error)"
        if case NurbyError.Failed(let msg) = error { text = msg }
        if text.hasPrefix("invalid parameters for `"), let r = text.range(of: "`: ") { text = String(text[r.upperBound...]) }
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Run a read-only command and return its JSON result.
    func query(_ command: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        let studio = studio
        let json = String(data: (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        let text = await Task.detached { try? studio.execute(command: command, paramsJson: json) }.value
        return text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func inspect() async -> [String: Any]? {
        let studio = studio
        let text = await Task.detached { try? studio.inspectJson() }.value
        return text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Tap handling: a pick toggles in the selection; nil (empty space) clears it.
    func toggle(_ pick: Pick?) async {
        guard let pick else {
            if !selection.isEmpty { selection = []; _ = await execute("select.clear") }
            return
        }
        if let i = selection.firstIndex(of: pick) { selection.remove(at: i) } else { selection.append(pick) }
        await syncSelection()
        if selection.contains(pick), pickOrigins[pick.id] == nil { pickOrigins[pick.id] = await origins(of: pick) }
        pickOrigins = pickOrigins.filter { k, _ in selection.contains { $0.id == k } }
    }

    func deselect(_ pick: Pick) async {
        selection.removeAll { $0 == pick }
        pickOrigins[pick.id] = nil
        await syncSelection()
    }

    /// Select several picks at once (replacing the selection).
    func select(_ picks: [Pick]) async {
        var unique: [Pick] = []
        for p in picks where !unique.contains(p) { unique.append(p) }
        selection = unique
        pickOrigins = [:]
        await syncSelection()
    }

    /// The features that made a face or edge, read from SolidCraft's topology names: a face
    /// `F3:blend(F2:side:l1|F2:side:l4)` was made by feature 3; an edge `F2:top|F5:side:c1` lies
    /// between faces of features 2 and 5. Newest first.
    private func origins(of pick: Pick) async -> [Feature] {
        let names = await topology(of: pick.body)
        let list = pick.kind == .face ? names.faces : names.edges
        guard Int(pick.index) < list.count else { return [] }
        let ids = Self.featureIDs(in: list[Int(pick.index)])
        return ids.compactMap { id in features.first { $0.id == id } }.sorted { $0.position > $1.position }
    }

    /// SolidCraft's topology names for a body's faces and edges, by display index (cached until the model changes).
    private func topology(of body: String) async -> (faces: [String], edges: [String]) {
        if let t = topologyNames[body] { return t }
        func names(_ command: String, _ key: String) async -> [String] {
            guard let obj = await query(command, ["body": body]), let list = obj[key] as? [[String: Any]] else { return [] }
            var out = Array(repeating: "", count: (list.compactMap { $0["index"] as? Int }.max() ?? -1) + 1)
            for item in list { if let i = item["index"] as? Int, let n = item["name"] as? String { out[i] = n } }
            return out
        }
        let t = (await names("model.faces", "faces"), await names("model.edges", "edges"))
        topologyNames[body] = t
        return t
    }

    /// Show (or stop showing) the faces a feature made.
    func focus(_ f: Feature?) async {
        focusFeature = f
        await computeAffected()
    }

    private func computeAffected() async {
        guard let f = focusFeature else { if !affected.isEmpty { affected = [] }; return }
        var out: [Pick] = []
        for m in meshes {
            for (i, n) in await topology(of: m.name).faces.enumerated() where Self.featureIDs(in: n).first == f.id {
                out.append(Pick(kind: .face, body: m.name, index: UInt32(i), point: .zero))
            }
        }
        affected = out
    }

    /// Feature ids at the top level of a topology name (`F3:blend(F2:…)` → 3; `F2:top|F5:side` → 2, 5).
    static func featureIDs(in name: String) -> [String] {
        var parts: [String] = [], depth = 0, cur = ""
        for ch in name {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == "|" && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur)
        var ids: [String] = []
        for p in parts where p.hasPrefix("F") {
            let digits = p.dropFirst().prefix { $0.isNumber }
            if !digits.isEmpty, !ids.contains(String(digits)) { ids.append(String(digits)) }
        }
        return ids
    }

    private func syncSelection() async {
        if selection.isEmpty { _ = await execute("select.clear"); return }
        let items: [[String: Any]] = selection.map {
            ["type": $0.kind.rawValue, "body": $0.body, "index": Int($0.index), "point": [Double($0.point.x), Double($0.point.y), Double($0.point.z)]]
        }
        if let e = await execute("select.set", ["items": items]) { error = e }
    }

    func undo() async { await run("edit.undo") }
    func redo() async { await run("edit.redo") }

    /// Change a sketch dimension through its parameter (`d3`).
    func setDimension(_ param: String, to expr: String) async {
        await run("parameters.change", ["name": param, "expression": expr])
    }

    func setParameter(_ name: String, to expr: String) async {
        await run("parameters.change", ["name": name, "value": expr])
    }

    // MARK: Sketching

    /// Start a sketch on a standard plane (XY, XZ, YZ) or on a picked planar face.
    func beginSketch(plane: String) async { await run("sketch.create", ["plane": plane]) }

    func beginSketch(on face: Pick) async {
        await run("sketch.create", ["plane": ["face": [Double(face.point.x), Double(face.point.y), Double(face.point.z)], "body": face.body, "index": Int(face.index)]])
    }

    func editSketch(_ name: String) async { await run("sketch.edit", ["sketch": name]) }

    /// Lines, rectangles and circles; `construction` ones are reference geometry (dashed, not
    /// part of any profile).
    func addPolyline(_ points: [SIMD2<Double>], closed: Bool, construction: Bool = false) async {
        var p: [String: Any] = ["points": points.map { [$0.x, $0.y] }, "closed": closed]
        if construction { p["construction"] = true }
        await run("sketch.line", p)
    }

    func addRectangle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, construction: Bool = false) async {
        var p: [String: Any] = ["p0": [a.x, a.y], "p1": [b.x, b.y]]
        if construction { p["construction"] = true }
        await run("sketch.rectangle.two_point", p)
    }

    /// `sketch.circle.center` has no construction flag: a construction circle is drawn, then
    /// switched with `sketch.construction`.
    func addCircle(center c: SIMD2<Double>, radius r: Double, construction: Bool = false) async {
        let p: [String: Any] = ["center": [c.x, c.y], "radius": r]
        guard construction else { await run("sketch.circle.center", p); return }
        let made = await query("sketch.circle.center", p)
        if let curves = (made?["created"] as? [String: Any])?["curves"] as? [String], !curves.isEmpty {
            await setConstruction(curves, true)
        } else {
            await refresh()
        }
    }

    func deleteSketchCurves(_ ids: [String]) async { await run("sketch.delete", ["entities": ids]) }

    /// Dimension between two picked items (points, lines, circles) or one curve. SolidCraft picks
    /// the kind from what they are: two points or a point and a line → distance, two lines →
    /// angle (distance when parallel), a circle with anything → to its edge. An empty `value`
    /// keeps what it measures now.
    func dimension(entities: [String], value: String) async {
        var p: [String: Any] = ["entities": entities]
        let v = value.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { p["value"] = v }
        await run("sketch.dimension", p)
    }

    func finishSketch() async { await run("sketch.finish") }
    func cancelSketch() async { await run("sketch.cancel") }

    // MARK: Features

    enum Operation: String, CaseIterable { case join, cut, intersect, new
        var label: String { switch self { case .join: "Add"; case .cut: "Cut"; case .intersect: "Intersect"; case .new: "New" } }
        /// As a feature definition stores it.
        var stored: String { self == .new ? "new_body" : rawValue }
        init(stored: String?) {
            switch stored?.lowercased() {
            case "cut": self = .cut
            case "intersect": self = .intersect
            case "new_body", "new": self = .new
            default: self = .join
            }
        }
    }

    /// Everything `solid.extrude` takes from the panel: SolidCraft's `Extent` (direction, second
    /// side, through all, to / from a face with offsets, start offset, taper) plus thin walls.
    struct ExtrudeOptions: Equatable {
        enum Sides: String, CaseIterable { case one, flipped, symmetric, two
            var label: String { switch self { case .one: "One side"; case .flipped: "Flipped"; case .symmetric: "Symmetric"; case .two: "Two sides" } }
            var direction: String { switch self { case .flipped: "negative"; case .symmetric: "symmetric"; default: "positive" } }
        }
        enum End: String, CaseIterable { case distance, throughAll, toFace
            var label: String { switch self { case .distance: "Distance"; case .throughAll: "Through all"; case .toFace: "To face" } }
        }
        enum Start: String, CaseIterable { case sketch, offset, fromFace
            var label: String { switch self { case .sketch: "Sketch plane"; case .offset: "Offset"; case .fromFace: "From face" } }
        }
        enum ThinSide: String, CaseIterable { case center, inside, outside, two_sides
            var label: String { switch self { case .center: "Centre"; case .inside: "Inside"; case .outside: "Outside"; case .two_sides: "Both" } }
        }
        var distance = "10"
        var operation: Operation = .join
        var sides: Sides = .one
        var distance2 = "10"
        var end: End = .distance
        var toFace: SIMD3<Double>?
        var toOffset = ""
        var start: Start = .sketch
        var startOffset = "0"
        var fromFace: SIMD3<Double>?
        var taper = ""
        var thin = false
        var thickness = "2"
        var thinSide: ThinSide = .center
        var thickness2 = "2"
        /// The sketch to extrude (name; nil: SolidCraft's default, the active or last sketch).
        var sketch: String?
        /// The regions picked, by index (empty: the sketch's default profiles).
        var profiles: Set<Int> = []

        static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

        /// `solid.extrude` params for a new extrude.
        var params: [String: Any] {
            var p: [String: Any] = ["operation": operation.rawValue]
            if let sketch { p["sketch"] = sketch }
            if !profiles.isEmpty && !thin {
                p["profiles"] = profiles.sorted()
                p["exact_regions"] = true
            }
            if end == .distance { p["distance"] = distance }
            if end == .throughAll { p["through_all"] = true }
            if end == .toFace, let f = toFace {
                p["to"] = [f.x, f.y, f.z]
                if !Self.blank(toOffset) { p["to_offset"] = toOffset }
            }
            if sides != .one { p["direction"] = sides.direction }
            if sides == .two { p["distance2"] = distance2 }
            if start == .offset, !Self.blank(startOffset) { p["start_offset"] = startOffset }
            if start == .fromFace, let f = fromFace { p["from"] = [f.x, f.y, f.z] }
            if !Self.blank(taper) { p["taper"] = taper }
            if thin {
                p["thin"] = true
                p["thickness"] = thickness
                if thinSide != .center { p["side"] = thinSide.rawValue }
                if thinSide == .two_sides { p["thickness2"] = thickness2 }
            }
            return p
        }

        /// What still has to be picked or typed before it can run.
        var missing: String? {
            if end == .toFace && toFace == nil { return "Pick the face to extrude to." }
            if start == .fromFace && fromFace == nil { return "Pick the face to start from." }
            if end == .distance && Self.blank(distance) { return "Enter a distance." }
            if sides == .two && Self.blank(distance2) { return "Enter the second side's distance." }
            if thin && Self.blank(thickness) { return "Enter the wall thickness." }
            return nil
        }
    }

    func extrude(_ o: ExtrudeOptions) async -> Bool { await run("solid.extrude", o.params) }

    func revolve(angle: String, axis: String, operation: Operation) async -> Bool {
        await run("solid.revolve", ["angle": angle, "axis": axis, "operation": operation.rawValue])
    }

    private var pickedEdges: [[String: Any]] { selection.filter { $0.kind == .edge }.map { ["body": $0.body, "index": Int($0.index)] } }

    func fillet(radius: String) async -> Bool { await run("solid.fillet", ["edges": pickedEdges, "radius": radius]) }
    func chamfer(distance: String) async -> Bool { await run("solid.chamfer", ["edges": pickedEdges, "distance": distance]) }

    func shell(thickness: String) async -> Bool {
        let faces = selection.filter { $0.kind == .face }.map { [Double($0.point.x), Double($0.point.y), Double($0.point.z)] }
        return await run("solid.shell", ["faces": faces, "thickness": thickness])
    }

    // MARK: Editing features

    func definition(of f: Feature) async -> Definition? {
        guard let obj = await query("timeline.inspect", ["feature": f.name]) else { return nil }
        let inputs = (obj["inputs"] as? [[String: Any]] ?? []).compactMap { i -> Definition.Input? in
            guard let p = i["param"] as? String else { return nil }
            return .init(param: p, label: i["label"] as? String ?? p, expression: i["expression"] as? String ?? "", unit: i["unit"] as? String ?? "")
        }
        return Definition(inputs: inputs, raw: obj["definition"] as? [String: Any] ?? [:])
    }

    /// Change a feature: its numeric inputs (by parameter, e.g. `d1`) and definition fields
    /// (`timeline.edit` `set`, e.g. `{"operation": "cut"}`). One refresh at the end.
    func edit(_ f: Feature, inputs: [String: String], set: [String: Any]) async -> Bool {
        let failure = await applyEdit(f, inputs: inputs, set: set)
        error = failure
        await refresh()
        return failure == nil
    }

    // MARK: Rollback bar

    /// How many features are active: the rollback bar sits after this many rows.
    var marker: Int { features.firstIndex { $0.rolledBack } ?? features.count }

    /// Move the rollback bar: keep the first `k` features active (the rest show greyed and are
    /// not built; new features go in at the bar). `k` past the end puts it back at the end.
    func rollTo(_ k: Int) async {
        guard k != marker else { return }
        await run("timeline.roll_to", k >= features.count ? [:] : ["position": max(k, 0)])
    }

    // MARK: Live preview

    /// While a feature panel previews its values, the design as it was when the panel opened
    /// (`edit.checkpoint`, which keeps the undo history too). Each preview goes back to it and
    /// applies the panel's values again; Cancel goes back to it; Apply goes back and applies once,
    /// so undo sees one step. Nothing is saved while previewing.
    private var previewCheckpoint: Int?
    private var previewRunning = false
    private var previewPending: (() async -> String?)?
    private(set) var previewing = false
    /// Why the latest preview failed (the panel shows it); nil when it built.
    private(set) var previewError: String?

    private func checkpoint() async -> Int? {
        (await query("edit.checkpoint"))?["checkpoint"] as? Int
    }

    /// Back to the checkpoint, and take a new one there (restoring uses it up).
    private func rewind() async {
        guard let cp = previewCheckpoint else { return }
        if let e = await execute("edit.restore_checkpoint", ["checkpoint": cp]) { error = e }
        previewCheckpoint = await checkpoint()
    }

    private func previewIdle() async {
        previewPending = nil
        while previewRunning { try? await Task.sleep(for: .milliseconds(15)) }
    }

    func beginPreview() async {
        guard previewCheckpoint == nil else { return }
        previewCheckpoint = await checkpoint()
        previewing = previewCheckpoint != nil
        previewError = nil
    }

    /// Show `change` (engine commands, run without refreshing; returns the error) on top of the
    /// design as it was. Calls that come in while one is building are folded into the latest.
    func preview(_ change: @escaping () async -> String?) async {
        guard previewing else { return }
        previewPending = change
        guard !previewRunning else { return }
        previewRunning = true
        while let next = previewPending {
            previewPending = nil
            await rewind()
            previewError = await next()
            error = nil
            await refresh()
        }
        previewRunning = false
    }

    /// Preview the design as it was (no change).
    func previewOriginal() async { await preview { nil } }

    /// Leave the preview: back to the design as it was, or (with `commit`) as it was plus `commit`.
    @discardableResult
    func endPreview(commit: (() async -> Bool)? = nil) async -> Bool {
        guard previewing else { return await commit?() ?? true }
        previewing = false   // first, so a second call (Cancel, then the panel going away) does nothing
        await previewIdle()
        await rewind()
        previewError = nil
        var ok = true
        if let commit {
            ok = await commit()
            if !ok {
                // Back to where the panel started, still previewing, so the values can be fixed.
                let failure = error
                previewing = true
                await rewind()
                await refresh()
                error = failure
                previewError = failure
                return false
            }
        } else {
            await refresh()
        }
        if let cp = previewCheckpoint { _ = await execute("edit.restore_checkpoint", ["checkpoint": cp, "forget": true]) }
        previewCheckpoint = nil
        return ok
    }

    /// While previewing: the design as it was, rolled back to just before `f`, with `edges` picked
    /// (to re-pick a fillet's or chamfer's edges).
    func previewRolledBack(before f: Feature, edges: [SIMD3<Double>]) async {
        guard previewing else { return }
        await previewIdle()
        previewRunning = true
        await rewind()
        _ = await execute("timeline.roll_to", ["position": f.position])
        await refresh()
        previewRunning = false
        await selectEdges(at: edges)
    }

    /// The raw edit (no refresh): inputs through `parameters.change`, the rest through `timeline.edit`.
    func applyEdit(_ f: Feature, inputs: [String: String], set: [String: Any]) async -> String? {
        for (param, expr) in inputs {
            if let e = await execute("parameters.change", ["name": param, "expression": expr]) { return e }
        }
        if !set.isEmpty { return await execute("timeline.edit", ["feature": f.name, "set": set]) }
        return nil
    }

    /// A raw engine command for a preview (no refresh).
    func previewCommand(_ command: String, _ params: [String: Any]) async -> String? { await execute(command, params) }

    /// Show the model as it was just before `f` (to re-pick its edges or faces).
    func rollBack(before f: Feature) async { await run("timeline.roll_to", ["position": f.position]) }
    /// Back to the end of the timeline.
    func rollForward() async { await run("timeline.roll_to") }

    /// Select edges by points on them (a fillet's stored edges) in the current model.
    func selectEdges(at points: [SIMD3<Double>]) async {
        var picks: [Pick] = []
        for p in points {
            guard let hit = nearestEdge(to: SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))) else { continue }
            if !picks.contains(hit) { picks.append(hit) }
        }
        await select(picks)
    }

    /// Select faces by points on them (an extrude's to / from faces) in the current model.
    func selectFaces(at points: [SIMD3<Double>]) async {
        var picks: [Pick] = []
        for p in points {
            let q = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            guard let hit = nearestFace(to: q) else { continue }
            if !picks.contains(hit) { picks.append(hit) }
        }
        if picks != selection { await select(picks) }
    }

    /// The display face nearest a model point (within 1 mm), kept at that point.
    private func nearestFace(to p: SIMD3<Float>) -> Pick? {
        var best: (Float, Pick)?
        for m in meshes {
            let v = m.positions, ix = m.indices
            func vert(_ i: UInt32) -> SIMD3<Float> { let k = Int(i) * 3; return SIMD3(v[k], v[k + 1], v[k + 2]) }
            for t in 0..<min(m.triangleFaces.count, ix.count / 3) {
                let d = Self.distance(p, vert(ix[t * 3]), vert(ix[t * 3 + 1]), vert(ix[t * 3 + 2]))
                if d < 1, best == nil || d < best!.0 {
                    best = (d, Pick(kind: .face, body: m.name, index: m.triangleFaces[t], point: p))
                }
            }
        }
        return best?.1
    }

    /// Distance from a point to a triangle.
    private static func distance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let n = simd_cross(b - a, c - a), l = simd_length(n)
        if l > 1e-9 {
            let nn = n / l, h = simd_dot(p - a, nn), q = p - nn * h
            // Inside the triangle: the distance to its plane.
            let c0 = simd_dot(simd_cross(b - a, q - a), nn), c1 = simd_dot(simd_cross(c - b, q - b), nn), c2 = simd_dot(simd_cross(a - c, q - c), nn)
            if c0 >= 0 && c1 >= 0 && c2 >= 0 { return abs(h) }
        }
        func seg(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d = b - a, l2 = simd_length_squared(d)
            let t = l2 == 0 ? 0 : max(0, min(1, simd_dot(p - a, d) / l2))
            return simd_distance(p, a + d * t)
        }
        return min(seg(a, b), seg(b, c), seg(c, a))
    }

    /// The display edge nearest a model point (within 1 mm).
    private func nearestEdge(to p: SIMD3<Float>) -> Pick? {
        var best: (Float, Pick)?
        for m in meshes {
            let e = m.edges
            for s in 0..<m.segmentEdges.count {
                let a = SIMD3(e[s * 6], e[s * 6 + 1], e[s * 6 + 2]), b = SIMD3(e[s * 6 + 3], e[s * 6 + 4], e[s * 6 + 5])
                let d = b - a, l2 = simd_length_squared(d)
                let t = l2 == 0 ? 0 : max(0, min(1, simd_dot(p - a, d) / l2))
                let dist = simd_distance(p, a + d * t)
                if dist < 1, best == nil || dist < best!.0 {
                    best = (dist, Pick(kind: .edge, body: m.name, index: m.segmentEdges[s], point: p))
                }
            }
        }
        return best?.1
    }

    var editedEdges: [[Double]] { selection.filter { $0.kind == .edge }.map { [Double($0.point.x), Double($0.point.y), Double($0.point.z)] } }

    func deleteFeature(_ f: Feature) async { await run("timeline.delete", ["feature": f.name]) }

    /// Move a step to `position` in the timeline (`timeline.reorder`). SolidCraft refuses a move
    /// that would break a step that builds now (a sketch on a face that would come later, an
    /// extrude before its sketch…) and says why; that shows as the drawer's error.
    func reorder(_ f: Feature, to position: Int) async {
        guard position != f.position else { return }
        await run("timeline.reorder", ["feature": f.name, "position": position])
    }

    // MARK: Sketch regions (extrude profiles)

    /// Load the regions `sketch` (name or id) closes, for an extrude panel to choose from.
    /// `chosen` are the indices picked so far (empty: the extrude's default profiles).
    func loadRegions(sketch ref: Any, chosen: Set<Int> = []) async -> RegionPick? {
        guard let o = await query("sketch.inspect", ["sketch": ref]), let sk = Sketch(o) else { regionPick = nil; return nil }
        let studio = studio, id = UInt64(sk.id)
        let text = await Task.detached { try? studio.sketchRegions(sketch: id) }.value
        let list = text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] } ?? []
        func pts(_ a: Any?) -> [SIMD2<Double>] {
            (a as? [[Double]] ?? []).compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        }
        let regions = list.compactMap { r -> RegionPick.Region? in
            guard let i = r["index"] as? Int else { return nil }
            let outer = pts(r["outer"])
            guard outer.count >= 3 else { return nil }
            return .init(index: i, outer: outer, holes: (r["holes"] as? [Any] ?? []).map(pts).filter { $0.count >= 3 },
                         curves: i < sk.profileCurves.count ? sk.profileCurves[i] : [])
        }
        let pick = RegionPick(sketch: sk, regions: regions, chosen: chosen.filter { i in regions.contains { $0.index == i } })
        regionPick = pick
        return pick
    }

    func toggleRegion(_ index: Int) {
        guard var p = regionPick else { return }
        if p.chosen.contains(index) { p.chosen.remove(index) } else { p.chosen.insert(index) }
        regionPick = p
    }

    // MARK: Sketch constraints

    /// Run a sketch constraint (`sketch.constraint.*`), or any sketch command, and refresh.
    @discardableResult
    func sketchCommand(_ command: String, _ params: [String: Any]) async -> Bool { await run(command, params) }

    /// Make curves construction geometry (or normal again): `sketch.construction`.
    func setConstruction(_ curves: [String], _ on: Bool) async {
        await run("sketch.construction", ["curves": curves, "value": on])
    }

    /// Bring a model edge or face into the open sketch as construction geometry linked to it
    /// (`sketch.project`), so its ends, middle and centre can be dimensioned and constrained to.
    /// A face whose outline is four lines also gets a construction diagonal: its middle is the
    /// face's centre.
    func project(_ pick: Pick) async {
        let at = [Double(pick.point.x), Double(pick.point.y), Double(pick.point.z)]
        let ref: [String: Any] = [pick.kind.rawValue: at, "body": pick.body]
        let studio = studio
        let json = String(data: (try? JSONSerialization.data(withJSONObject: ["refs": [ref], "construction": true])) ?? Data(), encoding: .utf8) ?? "{}"
        let result: Result<String, Error> = await Task.detached { Result { try studio.execute(command: "sketch.project", paramsJson: json) } }.value
        switch result {
        case .failure(let e):
            error = DesignModel.message(e)
            await refresh()
        case .success(let text):
            error = nil
            await refresh()
            guard pick.kind == .face, let sk = sketch,
                  let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let created = o["created"] as? [String: Any] else { return }
            let curves = (created["curves"] as? [String] ?? []).compactMap { id in sk.curves.first { $0.id == id } }
            guard curves.count == 4, curves.allSatisfy({ $0.kind == .line }) else { return }
            // Opposite corners: the two created points farthest apart.
            let ids = (created["points"] as? [String] ?? []).compactMap { id in sk.pointIDs.firstIndex(of: id).map { (id, sk.points[$0]) } }
            var best: (String, String, Double)?
            for a in ids { for b in ids where a.0 < b.0 {
                let d = simd_distance(a.1, b.1)
                if d > (best?.2 ?? 0) { best = (a.0, b.0, d) }
            } }
            if let best { await run("sketch.line", ["points": [best.0, best.1], "construction": true]) }
        }
    }
    func renameFeature(_ f: Feature, to name: String) async { await run("timeline.rename", ["feature": f.name, "name": name]) }
    func addParameter(name: String, expression: String) async { await run("parameters.add", ["name": name, "expression": expression]) }
    func deleteParameter(_ name: String) async { await run("parameters.delete", ["name": name]) }

    // MARK: Files

    /// Export to Documents/Exports; returns the file's URL.
    func export(as ext: String) async -> URL? {
        let url = Self.exportsDir.appending(path: "\(name).\(ext)")
        try? FileManager.default.removeItem(at: url)
        return await run("file.export", ["path": url.path]) ? url : nil
    }

    func newDesign() async {
        viewingVersion = nil; workspace = nil
        await run("file.new")
        UserDefaults.standard.removeObject(forKey: Self.lastKey)
    }

    /// Open a design (.sc), or a STEP/IGES/STL/3MF/OBJ/glTF file as a new design holding it.
    @discardableResult
    func open(_ url: URL) async -> Bool {
        viewingVersion = nil; workspace = nil
        let ok = await run("doc.open", ["path": url.path])
        if ok, url.pathExtension.lowercased() != "sc", path == nil, !features.isEmpty {
            await save()   // an imported file becomes a design of its own, named after it
        }
        return ok
    }

    /// Copy a file picked in the Files app into Imports, then open it.
    func importFile(_ picked: URL) async {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let dest = Self.freeURL(base: picked.deletingPathExtension().lastPathComponent, ext: picked.pathExtension, in: Self.importsDir)
        do {
            try FileManager.default.copyItem(at: picked, to: dest)
        } catch {
            self.error = "Couldn't read \(picked.lastPathComponent): \(error.localizedDescription)"
            return
        }
        if dest.pathExtension.lowercased() == "sc" {
            let design = Self.freeURL(base: dest.deletingPathExtension().lastPathComponent)
            try? FileManager.default.moveItem(at: dest, to: design)
            await open(design)
        } else {
            await open(dest)
        }
    }

    /// Rename the open design's file.
    func rename(to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != name else { return }
        let old = path
        let dest = Self.freeURL(base: clean)
        if await run("file.save_as", ["path": dest.path]), let old, old != dest.path {
            Self.moveVersions(from: URL(filePath: old), to: dest)
            versionsFor = nil
            loadVersions()
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: old + ".bak")
            Thumbnails.remove(for: URL(filePath: old))
            Thumbnails.save(meshes, for: dest)
        }
    }

    /// Rename a saved design's file (the open one through SolidCraft, so it keeps its path).
    func rename(_ saved: SavedDesign, to newName: String) async {
        if saved.url.path == path { await rename(to: newName); return }
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != saved.name else { return }
        let dest = Self.freeURL(base: clean)
        do { try FileManager.default.moveItem(at: saved.url, to: dest) } catch { self.error = error.localizedDescription; return }
        Self.moveVersions(from: saved.url, to: dest)
        try? FileManager.default.removeItem(atPath: saved.url.path + ".bak")
        try? FileManager.default.moveItem(at: Thumbnails.url(for: saved.url), to: Thumbnails.url(for: dest))
    }

    /// Duplicate the open design and switch to the copy.
    func duplicate() async {
        let dest = Self.freeURL(base: "\(name) copy")
        if await run("file.save_as", ["path": dest.path]) { Thumbnails.save(meshes, for: dest) }
    }

    /// Delete a design file; a new, empty design replaces it if it is the open one.
    func delete(_ url: URL) async {
        if url.path == path { await newDesign() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".bak")
        try? FileManager.default.removeItem(at: Self.versionsDir(for: url))
        Thumbnails.remove(for: url)
    }

    /// A design's versions follow it when it is renamed.
    private static func moveVersions(from old: URL, to new: URL) {
        let a = versionsDir(for: old), b = versionsDir(for: new)
        guard FileManager.default.fileExists(atPath: a.path) else { return }
        try? FileManager.default.removeItem(at: b)
        try? FileManager.default.moveItem(at: a, to: b)
    }

    struct SavedDesign: Identifiable, Hashable { var id: URL { url }; let url: URL; let modified: Date; var name: String { url.deletingPathExtension().lastPathComponent } }

    /// Every design in Designs, newest first.
    static func savedDesigns() -> [SavedDesign] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: designsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "sc" }
            .map { SavedDesign(url: $0, modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }

    /// `base.ext` in `dir`, or `base 2.ext`, `base 3.ext`… if taken.
    static func freeURL(base: String, ext: String = "sc", in dir: URL = designsDir) -> URL {
        let fm = FileManager.default
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) \(n)"
            let url = dir.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// A small parametric part: a plate with parameters, four corner holes and rounded corners.
    func buildDemo() async {
        await run("parameters.add", ["name": "plate_w", "expression": "90 mm"])
        await run("parameters.add", ["name": "plate_d", "expression": "60 mm"])
        await run("parameters.add", ["name": "plate_t", "expression": "6 mm"])
        await run("parameters.add", ["name": "hole_d", "expression": "3.4 mm"])
        await run("sketch.create", ["plane": "XY", "name": "Plate outline"])
        await run("sketch.rectangle.two_point", ["p0": [0, 0], "p1": [90, 60]])
        await run("sketch.dimension", ["entities": ["l1"], "type": "length", "value": "plate_w"])
        await run("sketch.dimension", ["entities": ["l2"], "type": "length", "value": "plate_d"])
        await run("sketch.finish")
        await run("solid.extrude", ["sketch": "Plate outline", "distance": "plate_t", "name": "Plate body"])
        await run("sketch.create", ["plane": "XY", "name": "Hole pattern"])
        for c in [["6", "6"], ["plate_w - 6", "6"], ["plate_w - 6", "plate_d - 6"], ["6", "plate_d - 6"]] {
            await run("sketch.circle.center", ["center": c, "diameter": "hole_d"])
        }
        for i in 1...4 { await run("sketch.dimension", ["entities": ["c\(i)"], "type": "diameter", "value": "hole_d"]) }
        await run("sketch.finish")
        await run("solid.extrude", ["sketch": "Hole pattern", "distance": 10, "through_all": true, "operation": "cut", "name": "Mounting holes"])
        let corners: [[Any]] = [[0, 0, 3], [90, 0, 3], [90, 60, 3], [0, 60, 3]].map { [$0[0], $0[1], $0[2]] }
        await run("solid.fillet", ["edges": corners, "radius": 5, "name": "Corner rounds"])
    }

    /// On first launch, put a demo design in Designs (an ordinary design: rename or delete it).
    func seedDemoIfNeeded() async {
        let key = "seededDemo"
        guard !UserDefaults.standard.bool(forKey: key), path == nil, features.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        autosave = false
        defer { autosave = true }
        await run("file.new")
        await buildDemo()
        let dest = Self.freeURL(base: "Demo plate")
        if await run("file.save_as", ["path": dest.path]) { Thumbnails.save(meshes, for: dest) }
        await run("file.new")
        UserDefaults.standard.removeObject(forKey: Self.lastKey)
    }

    // MARK: document.inspect

    private static func features(in obj: [String: Any]) -> [Feature] {
        let list = obj["timeline"] as? [[String: Any]] ?? []
        return list.enumerated().compactMap { i, f in
            let name = f["name"] as? String ?? "Feature \(i + 1)"
            var kind = f["type"] as? String ?? ""
            if kind.hasSuffix("Feature") { kind = String(kind.dropLast("Feature".count)) }
            if f["suppressed"] as? Bool == true { kind += " · off" }
            let err = f["error"] as? String
            return Feature(id: "\(f["id"] ?? i)", name: name, kind: kind, detail: err ?? (f["warning"] as? String ?? ""), failed: err != nil,
                           position: i, rolledBack: f["rolled_back"] as? Bool == true)
        }
    }

    private static func parameters(in obj: [String: Any]) -> [Parameter] {
        let list = obj["params"] as? [[String: Any]] ?? []
        return list.compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            let expr = p["expression"] as? String ?? ""
            let unit = p["unit"] as? String ?? ""
            let value = (p["value"] as? Double).map { String(format: "%g", $0) + (unit.isEmpty ? "" : " \(unit)") } ?? ""
            return Parameter(name: name, expr: expr, value: value)
        }
    }
}

/// A sketch as `sketch.inspect` describes it: its plane in model mm and its curves in sketch
/// coordinates (mm along the plane's x and y).
struct Sketch: Equatable {
    struct Curve: Identifiable, Equatable {
        enum Kind { case line, circle, arc, other }
        let id: String
        let kind: Kind
        var start = SIMD2<Double>(0, 0), end = SIMD2<Double>(0, 0), center = SIMD2<Double>(0, 0)
        var radius = 0.0
        var construction = false
        /// Projected from the model (`sketch.project`, or a face sketch's outline): fixed, follows the model.
        var projected = false
        var length: Double { simd_distance(start, end) }
    }
    let id: Int
    let name: String
    let origin: SIMD3<Double>, xDir: SIMD3<Double>, yDir: SIMD3<Double>
    let curves: [Curve]
    let points: [SIMD2<Double>]
    /// SolidCraft's id for each of `points` (`origin`, `p3`, `c1.center`): what dimensions take.
    let pointIDs: [String]
    let profiles: Int
    /// Each profile's outer-loop curve ids (`sketch.inspect` `profiles[].curves`), by index.
    let profileCurves: [[String]]

    /// A driving dimension (`sketch.dimension`): on a line (length) or circle/arc (diameter,
    /// radius), with its expression and the parameter (`dN`) that holds it.
    struct Dimension: Identifiable, Equatable {
        let id: String
        let type: String
        let expression: String
        let param: String?
        let value: Double
        /// The single curve it measures (a length, diameter or radius).
        let curve: Int?
        /// What a dimension between two things ties: point indices (`p`, `q`) and curve indices
        /// (`l` a line, `c` a circle or arc, `a`/`b` two curves), as `sketch.inspect` gives them.
        var p: Int?, q: Int?, l: Int?, c: Int?, a: Int?, b: Int?
    }
    let dimensions: [Dimension]
    /// Horizontal / vertical constraints, by curve index.
    let alignments: [(curve: Int, vertical: Bool)]
    /// Other geometric constraints as small glyphs beside the curves they hold (∥ ⊥ = T M ⋯),
    /// by curve index.
    let glyphs: [(curve: Int, text: String)]
    /// Points placed by expressions (`fixed_by`, e.g. `{"x": "plate_w"}`), shown as coordinate dimensions.
    let placed: [(at: SIMD2<Double>, x: String?, y: String?)]

    static func == (a: Sketch, b: Sketch) -> Bool {
        a.id == b.id && a.name == b.name && a.origin == b.origin && a.xDir == b.xDir && a.yDir == b.yDir
            && a.curves == b.curves && a.points == b.points && a.profiles == b.profiles && a.dimensions == b.dimensions
    }
    var normal: SIMD3<Double> { simd_normalize(simd_cross(xDir, yDir)) }

    init?(_ o: [String: Any]) {
        let plane = (o["world_plane"] ?? o["plane"]) as? [String: Any]
        func v3(_ a: Any?) -> SIMD3<Double>? { (a as? [Double]).flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } }
        func v2(_ a: Any?) -> SIMD2<Double>? { (a as? [Double]).flatMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil } }
        guard let origin = v3(plane?["origin"]), let x = v3(plane?["x_dir"]), let y = v3(plane?["y_dir"]) else { return nil }
        self.origin = origin; xDir = x; yDir = y
        id = o["id"] as? Int ?? 0
        name = o["name"] as? String ?? "Sketch"
        curves = (o["curves"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            var k: Curve.Kind
            switch c["type"] as? String { case "line": k = .line; case "circle": k = .circle; case "arc": k = .arc; default: k = .other }
            var cv = Curve(id: id, kind: k)
            cv.start = v2(c["start_at"]) ?? .zero
            cv.end = v2(c["end_at"]) ?? .zero
            cv.center = v2(c["center_at"]) ?? .zero
            cv.radius = c["radius"] as? Double ?? 0
            cv.construction = c["construction"] as? Bool ?? false
            cv.projected = c["link"] is String
            return cv
        }
        let pts = o["points"] as? [[String: Any]] ?? []
        points = pts.compactMap { v2($0["at"]) }
        pointIDs = pts.compactMap { p in v2(p["at"]).map { _ in p["id"] as? String ?? "" } }
        placed = pts.compactMap { p in
            guard let at = v2(p["at"]), let f = p["fixed_by"] as? [String: Any] else { return nil }
            let x = f["x"].map { "\($0)" }, y = f["y"].map { "\($0)" }
            return x == nil && y == nil ? nil : (at, x, y)
        }
        let profs = o["profiles"] as? [[String: Any]] ?? []
        profiles = profs.count
        profileCurves = profs.map { $0["curves"] as? [String] ?? [] }
        let cons = o["constraints"] as? [[String: Any]] ?? []
        dimensions = cons.compactMap { c in
            guard let id = c["id"] as? String, let value = c["value"] as? Double else { return nil }
            let type = c["type"] as? String ?? ""
            let single = ["length", "diameter", "radius", "linear_diameter"].contains(type)
            var d = Dimension(id: id, type: type, expression: c["expression"] as? String ?? String(format: "%g", value),
                              param: c["param"] as? String, value: value, curve: single ? (c["l"] ?? c["c"]) as? Int : nil)
            d.p = c["p"] as? Int; d.q = c["q"] as? Int; d.l = c["l"] as? Int; d.c = c["c"] as? Int
            d.a = c["a"] as? Int; d.b = c["b"] as? Int
            return d
        }
        glyphs = cons.flatMap { c -> [(curve: Int, text: String)] in
            let t = (c["type"] as? String ?? "").lowercased()
            let sym: String? = t.hasPrefix("parallel") ? "∥" : t.hasPrefix("perpendicular") ? "⊥" : t.hasPrefix("equal") ? "="
                : t.hasPrefix("tangent") ? "T" : t.hasPrefix("collinear") ? "⋯" : t.hasPrefix("midpoint") ? "M"
                : t.hasPrefix("concentric") ? "◎" : t.hasPrefix("symmetr") ? "⇋" : nil
            guard let sym else { return [] }
            return [c["a"], c["b"], c["l"], c["c"]].compactMap { $0 as? Int }.map { (curve: $0, text: sym) }
        }
        alignments = cons.compactMap { c in
            guard let l = c["l"] as? Int, let t = c["type"] as? String, t == "horizontal" || t == "vertical" else { return nil }
            return (l, t == "vertical")
        }
    }

    /// Model point for sketch coordinates.
    func world(_ p: SIMD2<Double>) -> SIMD3<Double> { origin + xDir * p.x + yDir * p.y }
}

/// The regions of one sketch, for choosing which an extrude uses (`solid.extrude {profiles,
/// exact_regions}`): each region's boundary in sketch mm (from `Studio.sketchRegions`; a region
/// can be bounded by pieces of curves where shapes overlap) and the sketch's plane, so the
/// viewport can draw them and tell which one a tap lands in.
struct RegionPick: Equatable {
    struct Region: Identifiable, Equatable {
        let index: Int
        let outer: [SIMD2<Double>]
        let holes: [[SIMD2<Double>]]
        /// Curves of its outer loop (how an extrude may store the pick).
        let curves: [String]
        var id: Int { index }
        var area: Double { holes.reduce(abs(Self.area(outer))) { $0 - abs(Self.area($1)) } }
        static func area(_ p: [SIMD2<Double>]) -> Double {
            guard p.count > 2 else { return 0 }
            var a = 0.0
            for i in p.indices { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
            return a / 2
        }
        static func inside(_ pt: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
            var c = false, j = poly.count - 1
            for i in poly.indices {
                let a = poly[i], b = poly[j]
                if (a.y > pt.y) != (b.y > pt.y), pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
                j = i
            }
            return c
        }
        func contains(_ pt: SIMD2<Double>) -> Bool { Self.inside(pt, outer) && !holes.contains { Self.inside(pt, $0) } }
    }
    let sketch: Sketch
    let regions: [Region]
    /// Picked region indices; empty means the extrude's default (every drawn profile, nested
    /// loops as holes).
    var chosen: Set<Int>
    /// Off while the panel waits for a face tap (a to/from face), so the tap reaches the model.
    var tappable = true

    /// The smallest region containing a sketch point (the innermost, where regions nest).
    func region(at p: SIMD2<Double>) -> Region? {
        regions.filter { $0.contains(p) }.min { $0.area < $1.area }
    }

    /// Region indices for an extrude's stored `profiles` (`timeline.inspect`): indices, curve
    /// loops (matched to each region's outer curves) or points; empty for all.
    func indices(stored: Any?) -> Set<Int> {
        guard let o = stored as? [String: Any] else {
            return Set((stored as? [Int]) ?? [])
        }
        switch o["type"] as? String {
        case "indices": return Set(o["indices"] as? [Int] ?? [])
        case "curves":
            let loops = (o["loops"] as? [[String]] ?? []).map(Set.init)
            return Set(loops.compactMap { l in regions.first { Set($0.curves) == l }?.index })
        case "points":
            let pts = (o["points"] as? [[Double]] ?? []).compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            return Set(pts.compactMap { region(at: $0)?.index })
        default: return []
        }
    }
}
