import Foundation

/// A design's versions and branches. A version is a named copy of the design file; a branch is
/// a line of work with its own workspace. The design's own file always holds the branch being
/// worked on; the others' workspaces and every version live beside it in a hidden folder
/// (`Designs/.<name>.versions/`, which the Files app doesn't show), with `index.json`.
///
/// Switching branch parks the open workspace in that folder and opens the other one in its
/// place. Merging a branch into main makes main's workspace the branch's design (SolidCraft
/// can't combine two timelines); main's state before it is kept as a version, so nothing is lost.
struct VersionIndex: Codable, Equatable {
    struct Version: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var number: Int
        var name: String
        var branch: String
        var author: String
        var date: Date
        var file: String
    }
    struct Branch: Codable, Equatable, Identifiable, Hashable {
        var id: String { name }
        var name: String
        var created: Date
        /// The version it was started from (nil: from the workspace of the branch it came off).
        var from: String?
        var parent: String?
    }
    var branch = "main"
    var branches = [Branch(name: "main", created: .now)]
    var versions: [Version] = []

    var nextNumber: Int { (versions.map(\.number).max() ?? 0) + 1 }
    func version(_ id: String) -> Version? { versions.first { $0.id == id } }
}

/// What differs between two designs, by feature and parameter name.
struct DesignDiff {
    struct Row: Identifiable { let id = UUID(); let change: String; let name: String; let detail: String }
    var rows: [Row] = []
    var isEmpty: Bool { rows.isEmpty }
}

extension DesignModel {
    static let mainBranch = "main"

    /// The hidden folder that holds a design's versions and parked branch workspaces.
    static func versionsDir(for design: URL) -> URL {
        design.deletingLastPathComponent().appending(path: ".\(design.deletingPathExtension().lastPathComponent).versions", directoryHint: .isDirectory)
    }

    private var versionsDir: URL? { workspacePath.map { Self.versionsDir(for: URL(filePath: $0)) } }

    /// Read the open design's versions (an empty history, on main, when it has none yet).
    func loadVersions() {
        guard let dir = versionsDir, let data = try? Data(contentsOf: dir.appending(path: "index.json")),
              let index = try? JSONDecoder.versions.decode(VersionIndex.self, from: data) else {
            versions = VersionIndex()
            return
        }
        versions = index
    }

    private func storeVersions() {
        guard let dir = versionsDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.versions.encode(versions) {
            try? data.write(to: dir.appending(path: "index.json"), options: .atomic)
        }
    }

    private func branchFile(_ name: String) -> URL? {
        versionsDir?.appending(path: "branch-\(Self.safe(name)).sc")
    }

    private static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    /// A branch name from what was typed: lower case, words joined with dashes.
    static func branchName(_ typed: String) -> String {
        let words = typed.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.joined(separator: "-")
    }

    /// Save the workspace as a new version on the current branch.
    @discardableResult
    func saveVersion(named name: String, author: String = "You") async -> VersionIndex.Version? {
        guard viewingVersion == nil else { return nil }
        await save()
        guard let path, let dir = versionsDir else { error = "Save the design before making a version."; return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = versions.nextNumber
        let file = "v\(n)-\(UUID().uuidString.prefix(6)).sc"
        do {
            try FileManager.default.copyItem(at: URL(filePath: path), to: dir.appending(path: file))
        } catch {
            self.error = "Couldn't save the version: \(error.localizedDescription)"
            return nil
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = VersionIndex.Version(id: UUID().uuidString, number: n, name: clean.isEmpty ? "Version \(n)" : clean,
                                     branch: versions.branch, author: author, date: .now, file: file)
        versions.versions.append(v)
        storeVersions()
        return v
    }

    /// Show a version in the studio (not saved, and the workspace stays as it was) until `stopViewing`.
    func view(_ v: VersionIndex.Version) async {
        guard let dir = versionsDir else { return }
        if viewingVersion == nil {
            await save()
            workspace = path
        }
        viewingVersion = v
        _ = await run("doc.open", ["path": dir.appending(path: v.file).path])
    }

    /// Back to the workspace after viewing a version.
    func stopViewing() async {
        guard viewingVersion != nil, let ws = workspace else { return }
        viewingVersion = nil
        workspace = nil
        _ = await run("doc.open", ["path": ws])
    }

    /// Make the workspace the version's design. The workspace as it was is saved as a version first.
    func restore(_ v: VersionIndex.Version) async {
        await stopViewing()
        guard let path, let dir = versionsDir else { return }
        await saveVersion(named: "Before restoring V\(v.number)", author: "You")
        await replaceWorkspace(path: path, with: dir.appending(path: v.file))
    }

    /// Copy a design file over the workspace and open it.
    private func replaceWorkspace(path: String, with source: URL) async {
        let fm = FileManager.default
        let tmp = URL(filePath: path + ".incoming")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: source, to: tmp)
            _ = try fm.replaceItemAt(URL(filePath: path), withItemAt: tmp)
        } catch {
            self.error = "Couldn't open that version: \(error.localizedDescription)"
            return
        }
        _ = await run("doc.open", ["path": path])
        if let path = self.path { Thumbnails.save(meshes, for: URL(filePath: path)) }
    }

    /// Start a branch from the workspace, or from a version, and switch to it.
    func newBranch(_ typed: String, from v: VersionIndex.Version? = nil) async {
        await stopViewing()
        let name = Self.branchName(typed)
        guard !name.isEmpty else { return }
        guard !versions.branches.contains(where: { $0.name == name }) else { error = "There is already a branch called \(name)."; return }
        await save()
        guard let path, let park = branchFile(versions.branch), let dir = versionsDir else { error = "Save the design before branching."; return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        try? fm.removeItem(at: park)
        do { try fm.copyItem(at: URL(filePath: path), to: park) } catch { self.error = error.localizedDescription; return }
        versions.branches.append(.init(name: name, created: .now, from: v?.id, parent: versions.branch))
        versions.branch = name
        storeVersions()
        if let v { await replaceWorkspace(path: path, with: dir.appending(path: v.file)) }
    }

    /// Park the workspace and open another branch's.
    func switchBranch(to name: String) async {
        await stopViewing()
        guard name != versions.branch, versions.branches.contains(where: { $0.name == name }) else { return }
        await save()
        guard let path, let park = branchFile(versions.branch), let target = branchFile(name) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { error = "Branch \(name) has no saved design."; return }
        try? fm.removeItem(at: park)
        do { try fm.copyItem(at: URL(filePath: path), to: park) } catch { self.error = error.localizedDescription; return }
        versions.branch = name
        storeVersions()
        await replaceWorkspace(path: path, with: target)
        try? fm.removeItem(at: target)
    }

    /// Main's workspace becomes the current branch's design (main's state before is kept as a
    /// version on main), and the studio switches to main.
    func mergeIntoMain() async {
        await stopViewing()
        let from = versions.branch
        guard from != Self.mainBranch else { return }
        await save()
        guard let path, let mainFile = branchFile(Self.mainBranch), let dir = versionsDir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        /// Copy a design file into the versions as a version on main.
        func keep(_ src: URL, _ name: String) {
            let n = versions.nextNumber
            let file = "v\(n)-\(UUID().uuidString.prefix(6)).sc"
            guard (try? fm.copyItem(at: src, to: dir.appending(path: file))) != nil else { return }
            versions.versions.append(.init(id: UUID().uuidString, number: n, name: name,
                                           branch: Self.mainBranch, author: "You", date: .now, file: file))
        }
        // Main as it was, then main as the merge leaves it.
        if fm.fileExists(atPath: mainFile.path) { keep(mainFile, "Main before merging \(from)") }
        keep(URL(filePath: path), "Merged \(from)")
        // The branch keeps its workspace; main takes a copy of it.
        if let park = branchFile(from) {
            try? fm.removeItem(at: park)
            try? fm.copyItem(at: URL(filePath: path), to: park)
        }
        try? fm.removeItem(at: mainFile)
        versions.branch = Self.mainBranch
        storeVersions()
        if let path = self.path { Thumbnails.save(meshes, for: URL(filePath: path)) }
        _ = await run("doc.open", ["path": path])
    }

    /// Delete a branch that isn't the current one or main (its versions stay in the list).
    func deleteBranch(_ name: String) async {
        guard name != versions.branch, name != Self.mainBranch, let file = branchFile(name) else { return }
        try? FileManager.default.removeItem(at: file)
        versions.branches.removeAll { $0.name == name }
        storeVersions()
    }

    /// The design file a branch's workspace is in now.
    func file(ofBranch name: String) -> URL? {
        name == versions.branch ? (workspacePath.map { URL(filePath: $0) }) : branchFile(name)
    }

    func file(of v: VersionIndex.Version) -> URL? { versionsDir?.appending(path: v.file) }

    /// Compare two design files: what `b` adds, removes or changes against `a` (features by name
    /// and kind, parameters by expression). Each is opened in a session of its own.
    func compare(_ a: URL, _ b: URL) async -> DesignDiff? {
        await save()
        let filesDir = Self.filesDir.path
        return await Task.detached { () -> DesignDiff? in
            func summary(_ url: URL) -> (features: [(String, String, Bool)], params: [String: String])? {
                guard let s = try? Studio(filesDir: filesDir) else { return nil }
                let json = String(data: (try? JSONSerialization.data(withJSONObject: ["path": url.path])) ?? Data(), encoding: .utf8) ?? "{}"
                guard (try? s.execute(command: "doc.open", paramsJson: json)) != nil,
                      let text = try? s.inspectJson(),
                      let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
                let features = (obj["timeline"] as? [[String: Any]] ?? []).map { f -> (String, String, Bool) in
                    var kind = f["type"] as? String ?? ""
                    if kind.hasSuffix("Feature") { kind = String(kind.dropLast("Feature".count)) }
                    return (f["name"] as? String ?? "", kind, f["suppressed"] as? Bool == true)
                }
                var params: [String: String] = [:]
                for p in obj["params"] as? [[String: Any]] ?? [] {
                    if let n = p["name"] as? String { params[n] = p["expression"] as? String ?? "" }
                }
                return (features, params)
            }
            guard let x = summary(a), let y = summary(b) else { return nil }
            var diff = DesignDiff()
            let xNames = Dictionary(x.features.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
            let yNames = Dictionary(y.features.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
            for f in y.features where xNames[f.0] == nil { diff.rows.append(.init(change: "Added", name: f.0, detail: f.1)) }
            for f in x.features where yNames[f.0] == nil { diff.rows.append(.init(change: "Removed", name: f.0, detail: f.1)) }
            for f in y.features {
                if let o = xNames[f.0], o.2 != f.2 { diff.rows.append(.init(change: f.2 ? "Turned off" : "Turned on", name: f.0, detail: f.1)) }
            }
            for (n, e) in y.params.sorted(by: { $0.key < $1.key }) {
                if let o = x.params[n] {
                    if o != e { diff.rows.append(.init(change: "Changed", name: n, detail: "\(o) → \(e)")) }
                } else if !n.hasPrefix("d") || Int(n.dropFirst()) == nil {
                    diff.rows.append(.init(change: "Added", name: n, detail: e))
                }
            }
            for (n, e) in x.params.sorted(by: { $0.key < $1.key }) where y.params[n] == nil && (!n.hasPrefix("d") || Int(n.dropFirst()) == nil) {
                diff.rows.append(.init(change: "Removed", name: n, detail: e))
            }
            return diff
        }.value
    }
}

extension JSONEncoder {
    static var versions: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var versions: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
