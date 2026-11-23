import SwiftUI

/// Blender-style view axes in the top right of the viewport: the model's X (red), Y (green) and
/// Z (blue) as seen from the camera, positive ends labelled. Tap an end to look along that axis
/// (tap the view you are in to flip to the opposite side), drag to orbit, hold to look square
/// onto the selected face (or the face in the middle of the view).
struct NavigationGizmo: View {
    let handle: ViewportHandle
    private let size: CGFloat = 96
    private let reach: CGFloat = 32
    private let ball: CGFloat = 9.5
    @State private var pressed = false
    @State private var moved = false
    @State private var held = false
    @State private var last: CGSize = .zero
    @State private var hold: Task<Void, Never>?

    private static let colors: [Color] = [Color(hex: 0xE5484D), Color(hex: 0x5BB35B), Color(hex: 0x3E8BE6)]
    private static let names = ["X", "Y", "Z"]

    private struct End { let axis: Int; let sign: Float; let at: CGPoint; let depth: Float }

    private var ends: [End] {
        let c = CGPoint(x: size / 2, y: size / 2)
        var out: [End] = []
        for a in 0..<3 {
            let v = handle.screenAxis(a)
            for s in [Float(1), -1] {
                out.append(End(axis: a, sign: s, at: CGPoint(x: c.x + CGFloat(v.x * s) * reach, y: c.y - CGFloat(v.y * s) * reach), depth: v.z * s))
            }
        }
        return out.sorted { $0.depth < $1.depth }   // far ends first
    }

    var body: some View {
        Canvas { ctx, _ in
            let c = CGPoint(x: size / 2, y: size / 2)
            for e in ends {
                let color = Self.colors[e.axis]
                let r = CGRect(x: e.at.x - ball, y: e.at.y - ball, width: ball * 2, height: ball * 2)
                if e.sign > 0 {
                    var line = Path(); line.move(to: c); line.addLine(to: e.at)
                    ctx.stroke(line, with: .color(color), style: .init(lineWidth: 2.2, lineCap: .round))
                    ctx.fill(Path(ellipseIn: r), with: .color(color))
                    ctx.draw(Text(Self.names[e.axis]).font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75)), at: e.at)
                } else {
                    ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(0.28)))
                    ctx.stroke(Path(ellipseIn: r.insetBy(dx: 0.75, dy: 0.75)), with: .color(color.opacity(0.85)), lineWidth: 1.5)
                }
            }
        }
        .frame(width: size, height: size)
        .background(.primary.opacity(pressed ? 0.14 : 0.06), in: .circle)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !pressed {
                    pressed = true; moved = false; held = false; last = .zero
                    hold = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, pressed, !moved else { return }
                        held = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        handle.alignNormal()
                    }
                }
                if !moved, hypot(v.translation.width, v.translation.height) > 5 { moved = true; hold?.cancel() }
                if moved && !held {
                    handle.orbit(dx: v.translation.width - last.width, dy: v.translation.height - last.height)
                    last = v.translation
                }
            }
            .onEnded { v in
                hold?.cancel()
                if !moved && !held { tap(v.location) }
                pressed = false
            })
        .animation(.easeOut(duration: 0.15), value: pressed)
        .accessibilityElement()
        .accessibilityLabel("View direction")
        .accessibilityHint("Tap an axis to look along it, hold to look straight at the face")
        .accessibilityActions {
            Button("Top") { handle.snap(axis: 2, sign: 1) }
            Button("Front") { handle.snap(axis: 1, sign: -1) }
            Button("Right") { handle.snap(axis: 0, sign: 1) }
            Button("Look at face") { handle.alignNormal() }
        }
    }

    /// The nearest end under the finger, front ends first.
    private func tap(_ p: CGPoint) {
        let hit = ends.reversed().first { hypot($0.at.x - p.x, $0.at.y - p.y) < ball + 6 }
        if let hit { handle.snap(axis: hit.axis, sign: hit.sign) }
    }
}
