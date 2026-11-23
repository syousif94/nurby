import SwiftUI

/// The modelling operations a feature panel edits directly.
enum FeatureKind: String, Identifiable {
    case extrude = "Extrude", revolve = "Revolve", fillet = "Fillet", chamfer = "Chamfer", shell = "Shell"
    var id: String { rawValue }
}

/// Icons-only glass capsule of CAD operations. Sketch and the common features run directly
/// (a feature opens a small panel); the rest start a request to the agent. Pressing shows the
/// operation's name.
struct OperationsBar: View {
    enum Action { case sketch, feature(FeatureKind), agent(String) }
    struct Op: Identifiable { let id: String; let symbol: String; let action: Action }
    static let ops: [Op] = [
        .init(id: "New sketch", symbol: "square.and.pencil", action: .sketch),
        .init(id: "Extrude", symbol: "cube", action: .feature(.extrude)),
        .init(id: "Revolve", symbol: "arrow.triangle.2.circlepath", action: .feature(.revolve)),
        .init(id: "Hole", symbol: "circle.circle", action: .agent("Add holes: ")),
        .init(id: "Fillet", symbol: "square.on.square.squareshape.controlhandles", action: .feature(.fillet)),
        .init(id: "Chamfer", symbol: "triangle", action: .feature(.chamfer)),
        .init(id: "Shell", symbol: "shippingbox", action: .feature(.shell)),
        .init(id: "Pattern", symbol: "square.grid.2x2", action: .agent("Pattern ")),
        .init(id: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: .agent("Mirror ")),
        .init(id: "Measure", symbol: "ruler", action: .agent("Measure the volume, mass in PLA and bounding box of the part.")),
    ]
    let design: DesignModel
    var feature: (FeatureKind) -> Void
    var agent: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Self.ops) { op in
                    switch op.action {
                    case .sketch:
                        Menu {
                            if let face = design.selection.first(where: { $0.kind == .face }) {
                                Button("On selected face", systemImage: "square.dashed.inset.filled") { Task { await design.beginSketch(on: face) } }
                                Divider()
                            }
                            Button("Top (XY)") { Task { await design.beginSketch(plane: "XY") } }
                            Button("Front (XZ)") { Task { await design.beginSketch(plane: "XZ") } }
                            Button("Right (YZ)") { Task { await design.beginSketch(plane: "YZ") } }
                        } label: { icon(op) }
                        .accessibilityLabel(op.id)
                    case .feature(let k):
                        Button { feature(k) } label: { icon(op) }
                            .buttonStyle(OpButtonStyle(name: op.id)).accessibilityLabel(op.id)
                    case .agent(let prompt):
                        Button { agent(prompt) } label: { icon(op) }
                            .buttonStyle(OpButtonStyle(name: op.id)).accessibilityLabel(op.id)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .tint(.primary)
        .scrollClipDisabled()
        .frame(maxWidth: CGFloat(Self.ops.count) * 44 + 16)
        .frame(height: 56)
        // Clip the icons to the capsule, but leave room above it for a pressed button's name.
        .mask {
            VStack(spacing: 0) {
                Rectangle().frame(height: 60)
                Capsule()
            }
            .padding(.top, -60)
        }
        .glassEffect(in: .capsule)
    }

    private func icon(_ op: Op) -> some View {
        Image(systemName: op.symbol).font(.system(size: 19)).frame(width: 42, height: 44).contentShape(.rect)
    }
}

/// A tool button in a bar: pressing it tints it and shows its name in a glass pill above it.
/// `highlight: false` leaves the look to the label (the sketch bar's tools draw their own state)
/// and just dims it while pressed.
struct OpButtonStyle: ButtonStyle {
    let name: String
    var highlight = true
    func makeBody(configuration: Configuration) -> some View { OpButtonBody(configuration: configuration, name: name, highlight: highlight) }

    /// A custom style loses the system's dimming of disabled buttons, so it is done here.
    private struct OpButtonBody: View {
        let configuration: Configuration
        let name: String
        let highlight: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
        configuration.label
            .opacity(enabled ? 1 : 0.35)
            .background(highlight && configuration.isPressed ? Theme.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 19))
            .foregroundStyle(highlight ? (configuration.isPressed ? Theme.accent : .primary) : .primary)
            .opacity(!highlight && configuration.isPressed ? 0.6 : 1)
            .overlay(alignment: .top) {
                if configuration.isPressed {
                    Text(name).font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(in: .capsule)
                        .fixedSize()
                        .offset(y: -50)
                }
            }
        }
    }
}
