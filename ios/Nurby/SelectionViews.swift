import SwiftUI

/// One picked face or edge as a row: colour dot (green face / orange edge), its name and the
/// feature that made it, and an ✕ that drops it from the selection.
struct PickRow: View {
    let pick: DesignModel.Pick
    var origin: String?
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pick.kind == .edge ? "line.diagonal" : "square.fill")
                .font(.system(size: pick.kind == .edge ? 13 : 10, weight: .bold))
                .foregroundStyle(Theme.selection(pick.kind))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(pick.label).font(.subheadline.weight(.medium)).lineLimit(1)
                if let origin { Text(origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 30).contentShape(.rect)
            }
            .tint(.secondary)
            .accessibilityLabel("Remove \(pick.label)")
        }
        .padding(.leading, 8)
        .frame(minHeight: 34)
        .background(Theme.selection(pick.kind).opacity(0.1), in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
    }
}

/// The picks of one kind (or all) as removable rows, for a feature panel.
struct PickList: View {
    let design: DesignModel
    var kind: DesignModel.Pick.Kind?
    /// Picks shown elsewhere (left out here).
    var exclude: (DesignModel.Pick) -> Bool = { _ in false }

    var body: some View {
        let picks = design.selection.filter { (kind == nil || $0.kind == kind) && !exclude($0) }
        VStack(spacing: 4) {
            ForEach(picks) { p in
                PickRow(pick: p, origin: design.pickOrigins[p.id]?.first?.name) { Task { await design.deselect(p) } }
            }
        }
        .animation(.easeOut(duration: 0.15), value: picks)
    }
}

/// A small floating glass card listing what is selected, so any of it (or all of it) can be
/// dropped quickly. Shown over the viewport while something is selected.
///
/// `compact` (narrow screens) starts it folded to a one-line summary pill so it doesn't cover the
/// view; feature panels list the selection themselves.
struct SelectionPanel: View {
    let design: DesignModel
    var compact = false
    @State private var expanded: Bool

    init(design: DesignModel, compact: Bool = false) {
        self.design = design
        self.compact = compact
        _expanded = State(initialValue: !compact)
    }

    var body: some View {
        let faces = design.selection.filter { $0.kind == .face }.count
        let edges = design.selection.count - faces
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text(Self.summary(faces: faces, edges: edges)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .contentShape(.rect)
                }
                .tint(.primary)
                .accessibilityLabel(expanded ? "Collapse selection" : "Expand selection")
                Spacer(minLength: 8)
                Button("Clear") { Task { await design.toggle(nil) } }
                    .font(.subheadline.weight(.medium))
                    .tint(Theme.accent)
                    .accessibilityLabel("Clear selection")
            }
            .padding(.horizontal, 6)
            if expanded {
                if design.selection.count > 5 {
                    ScrollView { PickList(design: design) }.frame(height: 200)
                } else {
                    PickList(design: design)
                }
            }
        }
        .padding(compact && !expanded ? 6 : 10)
        .frame(width: compact && !expanded ? nil : 260)
        .fixedSize(horizontal: compact && !expanded, vertical: false)
        .glassEffect(in: .rect(cornerRadius: 22))
    }

    static func summary(faces: Int, edges: Int) -> String {
        var parts: [String] = []
        if faces > 0 { parts.append("\(faces) face\(faces == 1 ? "" : "s")") }
        if edges > 0 { parts.append("\(edges) edge\(edges == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " · ")
    }
}
