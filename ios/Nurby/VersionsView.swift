import SwiftUI

/// The drawer's Versions tab: branches as filter chips, the workspace, the versions newest first
/// (tap one to view, restore, branch from or compare it), and New branch / Compare / Merge.
struct VersionsView: View {
    let design: DesignModel
    @State private var filter: String?
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var comparing: Comparison?
    @State private var confirmMerge = false

    enum Naming: Identifiable {
        case version, branch(from: VersionIndex.Version?)
        var id: String { switch self { case .version: "v"; case .branch(let v): "b" + (v?.id ?? "") } }
    }
    struct Comparison: Identifiable {
        let id = UUID()
        let title: String
        var diff: DesignDiff?
        var failed = false
    }

    private var index: VersionIndex { design.versions }
    private var shown: [VersionIndex.Version] {
        index.versions.filter { filter == nil || $0.branch == filter }.sorted { $0.number > $1.number }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            branchChips
            Button { nameText = ""; naming = .version } label: {
                Label("Save version", systemImage: "bookmark").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
            }
            .tint(Theme.accent)
            .disabled(design.path == nil || design.viewingVersion != nil)

            VStack(spacing: 2) {
                workspaceRow
                if shown.isEmpty {
                    Text(index.versions.isEmpty
                         ? "No versions yet. Save one to mark a point you can come back to; the agent saves one after each change it makes."
                         : "No versions on this branch yet.")
                        .font(.footnote).foregroundStyle(.secondary).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(shown) { v in versionRow(v) }
            }

            HStack(spacing: 8) {
                Button { nameText = ""; naming = .branch(from: nil) } label: { pill("New branch") }
                    .disabled(design.path == nil)
                Menu {
                    ForEach(index.branches.filter { $0.name != index.branch }) { b in
                        Button("With \(b.name)") { compare(branch: b.name) }
                    }
                    if let last = index.versions.filter({ $0.branch == index.branch }).max(by: { $0.number < $1.number }) {
                        Button("With V\(last.number) · \(last.name)") { compare(version: last) }
                    }
                } label: { pill("Compare") }
                    .disabled(index.branches.count < 2 && index.versions.isEmpty)
                Button { confirmMerge = true } label: { pill("Merge", strong: true) }
                    .disabled(index.branch == DesignModel.mainBranch)
                    .opacity(index.branch == DesignModel.mainBranch ? 0.4 : 1)
            }
            .tint(Theme.accent)
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(namingPlaceholder, text: $nameText).autocorrectionDisabled()
                .textInputAutocapitalization(naming.map { if case .version = $0 { .sentences } else { .never } } ?? .sentences)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(namingAction) {
                let text = nameText
                switch naming {
                case .version: Task { await design.saveVersion(named: text) }
                case .branch(let v): Task { await design.newBranch(text, from: v) }
                case nil: break
                }
                naming = nil
            }
        } message: {
            Text(namingMessage)
        }
        .confirmationDialog("Merge \(index.branch) into main?", isPresented: $confirmMerge, titleVisibility: .visible) {
            Button("Merge into main") { Task { await design.mergeIntoMain() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Main takes this branch's design and you switch to main. Main as it is now is kept as a version, and \(index.branch) stays as it is.")
        }
        .sheet(item: $comparing) { c in CompareSheet(comparison: c) }
    }

    // MARK: Pieces

    private var branchChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", on: filter == nil) { filter = nil }
                ForEach(index.branches) { b in
                    chip(b.name, on: filter == b.name, current: b.name == index.branch) { filter = b.name }
                        .contextMenu {
                            if b.name != index.branch {
                                Button("Switch to \(b.name)", systemImage: "arrow.triangle.branch") { Task { await design.switchBranch(to: b.name) } }
                                Button("Compare with \(index.branch)", systemImage: "rectangle.split.2x1") { compare(branch: b.name) }
                            }
                            if b.name != index.branch && b.name != DesignModel.mainBranch {
                                Button("Delete branch", systemImage: "trash", role: .destructive) { Task { await design.deleteBranch(b.name) } }
                            }
                        }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, current: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if current { Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .bold)) }
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(on ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06), in: .capsule)
            .foregroundStyle(on ? Theme.accent : .primary)
        }
        .accessibilityLabel(current ? "\(title), current branch" : title)
    }

    private func pill(_ title: String, strong: Bool = false) -> some View {
        Text(title).font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity).frame(height: 38)
            .foregroundStyle(strong ? .white : Theme.accent)
            .background(strong ? Theme.accent : Theme.accent.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var workspaceRow: some View {
        let viewing = design.viewingVersion != nil
        return Button { Task { await design.stopViewing() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(Theme.accent)
                Text("Workspace now").font(.subheadline.weight(.semibold))
                Spacer()
                Text(index.branch).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background(viewing ? Color.clear : Color.primary.opacity(0.06), in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityHint(viewing ? "Back to the workspace" : "")
    }

    private func versionRow(_ v: VersionIndex.Version) -> some View {
        let viewing = design.viewingVersion?.id == v.id
        return Menu {
            Button(viewing ? "Back to workspace" : "View", systemImage: viewing ? "arrow.uturn.backward" : "eye") {
                Task { if viewing { await design.stopViewing() } else { await design.view(v) } }
            }
            Button("Restore to workspace", systemImage: "clock.arrow.circlepath") { Task { await design.restore(v) } }
            Button("New branch from here…", systemImage: "arrow.triangle.branch") { nameText = ""; naming = .branch(from: v) }
            Button("Compare with workspace", systemImage: "rectangle.split.2x1") { compare(version: v) }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(v.branch == DesignModel.mainBranch ? Color.secondary.opacity(0.5) : Theme.accent).frame(width: 7, height: 7)
                Text("V\(v.number) · \(v.name)").font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(v.author) · \(v.date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background(viewing ? Theme.accent.opacity(0.14) : .clear, in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(.rect)
        }
        .tint(.primary)
    }

    // MARK: Naming

    private var namingTitle: String {
        switch naming { case .version: "Save version"; case .branch(let v): v.map { "Branch from V\($0.number)" } ?? "New branch"; case nil: "" }
    }
    private var namingPlaceholder: String { if case .version = naming { "What changed" } else { "Branch name, e.g. fan cutout" } }
    private var namingAction: String { if case .version = naming { "Save" } else { "Create" } }
    private var namingMessage: String {
        switch naming {
        case .version: "Saves the design as it is now on \(index.branch)."
        case .branch(let v):
            v == nil ? "Try something without touching \(index.branch): its work is kept as it is and you switch to the new branch."
                     : "Starts a branch from this version and switches to it; \(index.branch) is kept as it is."
        case nil: ""
        }
    }

    // MARK: Compare

    private func compare(branch: String) {
        guard let a = design.file(ofBranch: index.branch), let b = design.file(ofBranch: branch) else { return }
        run(Comparison(title: "\(branch) → \(index.branch)"), b, a)   // what this branch changes
    }

    private func compare(version v: VersionIndex.Version) {
        guard let a = design.file(of: v), let b = design.file(ofBranch: index.branch) else { return }
        run(Comparison(title: "V\(v.number) → workspace"), a, b)
    }

    private func run(_ c: Comparison, _ a: URL, _ b: URL) {
        comparing = c
        Task {
            let diff = await design.compare(a, b)
            if comparing?.id == c.id {
                comparing?.diff = diff
                comparing?.failed = diff == nil
            }
        }
    }
}

/// What differs between two designs, feature by feature and parameter by parameter.
private struct CompareSheet: View {
    let comparison: VersionsView.Comparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if comparison.failed {
                    ContentUnavailableView("Couldn't compare", systemImage: "exclamationmark.triangle", description: Text("One of the designs didn't open."))
                } else if let diff = comparison.diff {
                    if diff.isEmpty {
                        ContentUnavailableView("No differences", systemImage: "equal.circle", description: Text("Same features and parameters."))
                    } else {
                        List(diff.rows) { r in
                            HStack {
                                Text(r.change).font(.caption.weight(.semibold))
                                    .foregroundStyle(r.change == "Removed" ? Theme.conflict : r.change == "Added" ? Theme.selected : Theme.accent)
                                    .frame(width: 76, alignment: .leading)
                                Text(r.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text(r.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } else {
                    ProgressView("Comparing…")
                }
            }
            .navigationTitle(comparison.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
