import SwiftUI
import UIKit
import simd

/// The sketch editor's state: the 2D view onto the sketch plane (centre and zoom, which the
/// viewport's orthographic camera follows), the tool, what's being drawn, and what's picked.
@MainActor @Observable
final class SketchController {
    enum Tool: String, CaseIterable, Identifiable {
        case line, rectangle, circle, select, project
        var id: String { rawValue }
        var label: String { self == .project ? "Project model edges and faces" : rawValue.capitalized }
        var symbol: String {
            switch self {
            case .line: "line.diagonal"; case .rectangle: "rectangle"; case .circle: "circle"
            case .select: "hand.point.up.left"; case .project: "cube.transparent"
            }
        }
    }

    var tool: Tool = .rectangle { didSet { chain = []; drag = nil } }
    /// New lines, rectangles and circles are construction geometry (dashed; reference only, never
    /// part of a profile).
    var construction = false
    /// Sketch point at the middle of the screen, and screen points per mm.
    var center = SIMD2<Double>(0, 0)
    var ppm = 4.0
    var size = CGSize.zero
    /// Points of a line chain being drawn (committed on Done or when it closes).
    var chain: [SIMD2<Double>] = []
    /// A rectangle or circle being dragged out: start and current point.
    var drag: (SIMD2<Double>, SIMD2<Double>)?
    var hover: SIMD2<Double>?
    /// Picked curves and points (SolidCraft ids: `l1`, `c2`, `p3`, `c1.center`, `origin`), a
    /// line's middle (`mid:l1`) or a sketch axis (`x`, `y`), in the order they were tapped.
    var picked: [String] = []

    func togglePick(_ id: String) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }

    /// Points snapped to in the sketch (existing points), set from the design's sketch.
    var snapPoints: [SIMD2<Double>] = []
    /// The dimension whose value is being changed (tapped label).
    var editingDimension: DimensionMark?

    /// A dimension as drawn: its witness and dimension lines, and its label. `param` is the
    /// parameter that drives it (nil for read-only coordinate dimensions).
    struct DimensionMark: Identifiable {
        let id: String
        let text: String
        let expression: String
        let param: String?
        let path: Path
        let label: CGPoint
        var editable: Bool { param != nil }
    }

    /// Where each dimension of `sketch` goes on screen: lengths beside their line on the side
    /// away from the sketch's middle, diameters and radii on a leader at 45°, expression-placed
    /// points as coordinate dimensions from the axes.
    func dimensionMarks(_ sketch: Sketch) -> [DimensionMark] {
        var out: [DimensionMark] = []
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for c in sketch.curves { for p in [c.start, c.end, c.center] { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        let mid = lo.x.isFinite ? screen((lo + hi) / 2) : screen(.zero)
        func text(_ d: Sketch.Dimension, prefix: String = "") -> String {
            let angle = d.type == "angle"
            let shown = angle ? d.value * 180 / .pi : d.value   // angles are stored in radians
            let v = String(format: "%g", (shown * 1000).rounded() / 1000) + (angle ? "°" : "")
            let bare = d.expression.replacingOccurrences(of: angle ? "deg" : "mm", with: "").trimmingCharacters(in: .whitespaces)
            let plain = Double(bare) != nil
            return plain ? prefix + v : "\(prefix)\(d.expression) = \(v)"
        }
        for d in sketch.dimensions {
            guard let ci = d.curve, ci < sketch.curves.count else { continue }
            let cv = sketch.curves[ci]
            var path = Path()
            switch cv.kind {
            case .line:
                let a = screen(cv.start), b = screen(cv.end)
                let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.001)
                let u = CGPoint(x: dx / len, y: dy / len)
                var n = CGPoint(x: -u.y, y: u.x)
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                if (m.x - mid.x) * n.x + (m.y - mid.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
                let off: CGFloat = 28
                func at(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * k, y: p.y + n.y * k) }
                path.move(to: at(a, 5)); path.addLine(to: at(a, off + 5))
                path.move(to: at(b, 5)); path.addLine(to: at(b, off + 5))
                let da = at(a, off), db = at(b, off)
                path.move(to: da); path.addLine(to: db)
                for (p, s) in [(da, 1.0), (db, -1.0)] {   // arrowheads pointing outwards to the witness lines
                    let back = CGPoint(x: p.x + u.x * 8 * s, y: p.y + u.y * 8 * s)
                    path.move(to: CGPoint(x: back.x + n.x * 3.5, y: back.y + n.y * 3.5)); path.addLine(to: p)
                    path.addLine(to: CGPoint(x: back.x - n.x * 3.5, y: back.y - n.y * 3.5))
                }
                out.append(.init(id: d.id, text: text(d), expression: d.expression, param: d.param, path: path, label: at(m, off)))
            case .circle, .arc:
                let c = screen(cv.center), r = cv.radius * ppm
                let dir = CGPoint(x: cos(-.pi / 4), y: sin(-.pi / 4))
                let edge = CGPoint(x: c.x + dir.x * r, y: c.y + dir.y * r)
                let knee = CGPoint(x: c.x + dir.x * (r + 26), y: c.y + dir.y * (r + 26))
                let tail = CGPoint(x: knee.x + 16, y: knee.y)
                let diameter = d.type.contains("diameter") || (cv.kind == .circle && !d.type.contains("radius"))
                if diameter {
                    path.move(to: CGPoint(x: c.x - dir.x * r, y: c.y - dir.y * r)); path.addLine(to: edge)
                }
                path.move(to: edge); path.addLine(to: knee); path.addLine(to: tail)
                let back = CGPoint(x: edge.x + dir.x * 8, y: edge.y + dir.y * 8)
                let nn = CGPoint(x: -dir.y, y: dir.x)
                path.move(to: CGPoint(x: back.x + nn.x * 3.5, y: back.y + nn.y * 3.5)); path.addLine(to: edge)
                path.addLine(to: CGPoint(x: back.x - nn.x * 3.5, y: back.y - nn.y * 3.5))
                out.append(.init(id: d.id, text: text(d, prefix: diameter ? "⌀" : "R"), expression: d.expression, param: d.param,
                                 path: path, label: CGPoint(x: tail.x + 4, y: tail.y)))
            case .other: continue
            }
        }
        // Dimensions between two things: a dimension line between the two places it measures
        // (dashed past a line's end), the label beside its middle.
        for d in sketch.dimensions where d.curve == nil {
            guard let mark = betweenMark(d, sketch: sketch, label: text(d, prefix: d.type == "angle" ? "∠" : "")) else { continue }
            out.append(mark)
        }
        // Coordinate dimensions for points placed by expressions (read-only here).
        var seen: Set<String> = []   // a placement shared by several points (a hole pattern) is labelled once
        for (i, p) in sketch.placed.enumerated() {
            let s = screen(p.at), o = screen(.zero)
            if let x = p.x, seen.insert("x " + x).inserted {
                var path = Path()
                let y = s.y + 22
                path.move(to: CGPoint(x: o.x, y: y)); path.addLine(to: CGPoint(x: s.x, y: y))
                path.move(to: CGPoint(x: s.x, y: s.y + 4)); path.addLine(to: CGPoint(x: s.x, y: y + 4))
                out.append(.init(id: "px\(i)", text: "x = \(x)", expression: x, param: nil, path: path, label: CGPoint(x: (o.x + s.x) / 2, y: y)))
            }
            if let yv = p.y, seen.insert("y " + yv).inserted {
                var path = Path()
                let x = s.x + 22
                path.move(to: CGPoint(x: x, y: o.y)); path.addLine(to: CGPoint(x: x, y: s.y))
                path.move(to: CGPoint(x: s.x + 4, y: s.y)); path.addLine(to: CGPoint(x: x + 4, y: s.y))
                out.append(.init(id: "py\(i)", text: "y = \(yv)", expression: yv, param: nil, path: path, label: CGPoint(x: x, y: (o.y + s.y) / 2)))
            }
        }
        return out
    }

    /// Where a two-entity dimension is drawn, from the point / curve indices it ties.
    private func betweenMark(_ d: Sketch.Dimension, sketch: Sketch, label: String) -> DimensionMark? {
        func point(_ i: Int?) -> SIMD2<Double>? { i.flatMap { $0 < sketch.points.count ? sketch.points[$0] : nil } }
        func curve(_ i: Int?) -> Sketch.Curve? { i.flatMap { $0 < sketch.curves.count ? sketch.curves[$0] : nil } }
        /// The foot of `p` on the (infinite) line through `cv`.
        func foot(_ p: SIMD2<Double>, _ cv: Sketch.Curve) -> SIMD2<Double> {
            let d = cv.end - cv.start, l2 = simd_length_squared(d)
            return l2 == 0 ? cv.start : cv.start + d * (simd_dot(p - cv.start, d) / l2)
        }
        func edge(_ cv: Sketch.Curve, toward p: SIMD2<Double>) -> SIMD2<Double> {
            let v = p - cv.center, l = simd_length(v)
            return l < 1e-9 ? cv.center + SIMD2(cv.radius, 0) : cv.center + v / l * cv.radius
        }
        var a: SIMD2<Double>, b: SIMD2<Double>
        var extensions: [(SIMD2<Double>, SIMD2<Double>)] = []
        /// A dashed extension from a line's nearer end to the foot when the foot is off the segment.
        func extend(_ cv: Sketch.Curve, to f: SIMD2<Double>) {
            let d = cv.end - cv.start, l2 = simd_length_squared(d)
            guard l2 > 0 else { return }
            let t = simd_dot(f - cv.start, d) / l2
            if t < 0 { extensions.append((cv.start, f)) } else if t > 1 { extensions.append((cv.end, f)) }
        }
        switch d.type {
        case "distance", "distance_x", "distance_y":
            guard let p = point(d.p), let q = point(d.q) else { return nil }
            a = p; b = q
            if d.type == "distance_x" { b = SIMD2(q.x, p.y); extensions.append((q, b)) }
            if d.type == "distance_y" { b = SIMD2(p.x, q.y); extensions.append((q, b)) }
        case "point_line_distance":
            guard let p = point(d.p), let cv = curve(d.l) else { return nil }
            a = p; b = foot(p, cv); extend(cv, to: b)
        case "point_circle_distance":
            guard let p = point(d.p), let cv = curve(d.c) else { return nil }
            a = p; b = edge(cv, toward: p)
        case "line_circle_distance":
            guard let ln = curve(d.l), let cv = curve(d.c) else { return nil }
            let f = foot(cv.center, ln)
            a = f; b = edge(cv, toward: f); extend(ln, to: f)
        case "circle_circle_distance":
            guard let c1 = curve(d.a), let c2 = curve(d.b) else { return nil }
            a = edge(c1, toward: c2.center); b = edge(c2, toward: c1.center)
        case "angle":
            guard let l1 = curve(d.a), let l2 = curve(d.b) else { return nil }
            return angleMark(d, l1, l2, label: label)
        default:
            return nil
        }
        let sa = screen(a), sb = screen(b)
        var path = Path()
        for (from, to) in extensions {
            // Dashes drawn as short segments (one stroke style for every mark).
            let f = screen(from), t = screen(to), len = hypot(t.x - f.x, t.y - f.y)
            var s: CGFloat = 0
            while s < len {
                let e = min(s + 4, len)
                path.move(to: CGPoint(x: f.x + (t.x - f.x) * s / len, y: f.y + (t.y - f.y) * s / len))
                path.addLine(to: CGPoint(x: f.x + (t.x - f.x) * e / len, y: f.y + (t.y - f.y) * e / len))
                s += 7
            }
        }
        let dx = sb.x - sa.x, dy = sb.y - sa.y, len = hypot(dx, dy)
        path.move(to: sa); path.addLine(to: sb)
        let u = len > 0.001 ? CGPoint(x: dx / len, y: dy / len) : CGPoint(x: 1, y: 0)
        let n = CGPoint(x: -u.y, y: u.x)
        if len > 20 {
            for (p, s) in [(sa, 1.0), (sb, -1.0)] {
                let back = CGPoint(x: p.x + u.x * 8 * s, y: p.y + u.y * 8 * s)
                path.move(to: CGPoint(x: back.x + n.x * 3.5, y: back.y + n.y * 3.5)); path.addLine(to: p)
                path.addLine(to: CGPoint(x: back.x - n.x * 3.5, y: back.y - n.y * 3.5))
            }
        }
        let m = CGPoint(x: (sa.x + sb.x) / 2 + n.x * 14, y: (sa.y + sb.y) / 2 + n.y * 14)
        return .init(id: d.id, text: label, expression: d.expression, param: d.param, path: path, label: m)
    }

    /// An arc between two lines about where they cross (or about the first line's middle when parallel).
    private func angleMark(_ d: Sketch.Dimension, _ l1: Sketch.Curve, _ l2: Sketch.Curve, label: String) -> DimensionMark? {
        let d1 = l1.end - l1.start, d2 = l2.end - l2.start
        let cross = d1.x * d2.y - d1.y * d2.x
        guard abs(cross) > 1e-9 else { return nil }
        let t = ((l2.start.x - l1.start.x) * d2.y - (l2.start.y - l1.start.y) * d2.x) / cross
        let o = l1.start + d1 * t
        // Point each ray from the corner toward the far end of its line.
        func ray(_ l: Sketch.Curve) -> SIMD2<Double> {
            let far = simd_distance(l.start, o) > simd_distance(l.end, o) ? l.start : l.end
            let v = far - o, n = simd_length(v)
            return n > 1e-9 ? v / n : SIMD2(1, 0)
        }
        let r1 = ray(l1), r2 = ray(l2)
        let so = screen(o)
        let rad: CGFloat = 36
        let a1 = atan2(-r1.y, r1.x), a2 = atan2(-r2.y, r2.x)   // screen y is down
        var sweep = a2 - a1
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        var path = Path()
        for i in 0...24 {
            let a = a1 + sweep * Double(i) / 24
            let q = CGPoint(x: so.x + rad * cos(a), y: so.y + rad * sin(a))
            i == 0 ? path.move(to: q) : path.addLine(to: q)
        }
        let mid = a1 + sweep / 2
        let m = CGPoint(x: so.x + (rad + 18) * cos(mid), y: so.y + (rad + 18) * sin(mid))
        return .init(id: d.id, text: label, expression: d.expression, param: d.param, path: path, label: m)
    }

    /// The editable dimension whose label is under a screen point.
    func dimension(at p: CGPoint, in sketch: Sketch) -> DimensionMark? {
        dimensionMarks(sketch).filter(\.editable).first { m in
            let w = CGFloat(m.text.count) * 7.5 + 24
            return abs(p.x - m.label.x) < w / 2 && abs(p.y - m.label.y) < 18
        }
    }

    func screen(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - center.x) * ppm, y: size.height / 2 - (p.y - center.y) * ppm)
    }

    func sketchPoint(_ s: CGPoint) -> SIMD2<Double> {
        SIMD2(center.x + (s.x - size.width / 2) / ppm, center.y - (s.y - size.height / 2) / ppm)
    }

    /// Grid spacing in mm that keeps cells at least ~14 pt apart.
    var gridStep: Double {
        for s in [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000] where s * ppm >= 14 { return s }
        return 1000
    }

    /// A touch in sketch coordinates: on an existing point within 14 pt, else on the grid.
    func snapped(_ s: CGPoint) -> SIMD2<Double> {
        let raw = sketchPoint(s)
        let near = (snapPoints + chain).min { simd_distance($0, raw) < simd_distance($1, raw) }
        if let near, simd_distance(near, raw) * ppm < 14 { return near }
        let g = gridStep
        return SIMD2((raw.x / g).rounded() * g, (raw.y / g).rounded() * g)
    }

    /// Fit the sketch's curves (or a 100 mm area by its origin) into `visible`, the part of
    /// the screen the panels leave uncovered.
    func fit(_ sketch: Sketch?, in visible: CGRect? = nil) {
        let area = visible ?? CGRect(origin: .zero, size: size)
        guard area.width > 0, area.height > 0 else { return }
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for c in sketch?.curves ?? [] {
            for p in c.kind == .circle ? [c.center - c.radius, c.center + c.radius] : [c.start, c.end] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        }
        if !lo.x.isFinite { lo = SIMD2(-10, -10); hi = SIMD2(90, 60) }
        let span = simd_max(hi - lo, SIMD2(20, 20)) * 1.4
        ppm = min(area.width / span.x, area.height / span.y)
        if !ppm.isFinite || ppm <= 0 { ppm = 4 }
        // Put the middle of the curves at the middle of the visible area.
        let mid = (lo + hi) / 2
        center = mid - SIMD2((area.midX - size.width / 2) / ppm, -(area.midY - size.height / 2) / ppm)
    }
}

/// Draws the sketch plane's grid, the sketch's curves, and what's being drawn.
struct SketchCanvas: View {
    let sketch: Sketch
    let controller: SketchController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let c = controller
            let ink = Color.cyan
            let ground = Theme.ground(scheme)
            // Grid
            let step = c.gridStep
            let lo = c.sketchPoint(.zero), hi = c.sketchPoint(CGPoint(x: size.width, y: size.height))
            var grid = Path()
            var x = (lo.x / step).rounded(.down) * step
            while x <= hi.x { grid.move(to: c.screen(SIMD2(x, lo.y))); grid.addLine(to: c.screen(SIMD2(x, hi.y))); x += step }
            var y = (hi.y / step).rounded(.down) * step
            while y <= lo.y { grid.move(to: c.screen(SIMD2(lo.x, y))); grid.addLine(to: c.screen(SIMD2(hi.x, y))); y += step }
            ctx.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            var axes = Path()
            axes.move(to: c.screen(SIMD2(lo.x, 0))); axes.addLine(to: c.screen(SIMD2(hi.x, 0)))
            let px = c.picked.contains("x"), py = c.picked.contains("y")
            ctx.stroke(axes, with: .color(px ? Theme.selected : .red.opacity(0.45)), lineWidth: px ? 3 : 1)
            axes = Path()
            axes.move(to: c.screen(SIMD2(0, lo.y))); axes.addLine(to: c.screen(SIMD2(0, hi.y)))
            ctx.stroke(axes, with: .color(py ? Theme.selected : .green.opacity(0.45)), lineWidth: py ? 3 : 1)

            // Curves
            for cv in sketch.curves {
                var p = Path()
                switch cv.kind {
                case .circle:
                    let r = cv.radius * c.ppm, o = c.screen(cv.center)
                    p.addEllipse(in: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r))
                case .arc:
                    // Through start and end about the centre, counter-clockwise in sketch space.
                    let a0 = atan2(cv.start.y - cv.center.y, cv.start.x - cv.center.x)
                    let a1 = atan2(cv.end.y - cv.center.y, cv.end.x - cv.center.x)
                    var sweep = a1 - a0; if sweep <= 0 { sweep += 2 * .pi }
                    for i in 0...32 {
                        let a = a0 + sweep * Double(i) / 32
                        let q = c.screen(cv.center + cv.radius * SIMD2(cos(a), sin(a)))
                        i == 0 ? p.move(to: q) : p.addLine(to: q)
                    }
                default:
                    p.move(to: c.screen(cv.start)); p.addLine(to: c.screen(cv.end))
                }
                let picked = c.picked.contains(cv.id)
                // Projected model geometry is purple: it follows the model and can't be dragged.
                ctx.stroke(p, with: .color(picked ? Theme.selected : cv.projected ? Self.projected : ink),
                           style: StrokeStyle(lineWidth: picked ? 3.5 : cv.construction ? 1.5 : 2, dash: cv.construction ? [6, 4] : []))
            }
            // Line middles, pickable with Select (to tie a point to the middle of an edge).
            if c.tool == .select {
                for cv in sketch.curves where cv.kind == .line && cv.length * c.ppm > 30 {
                    let m = c.screen((cv.start + cv.end) / 2), r: CGFloat = c.picked.contains("mid:" + cv.id) ? 6 : 3.5
                    var d = Path()
                    d.move(to: CGPoint(x: m.x, y: m.y - r)); d.addLine(to: CGPoint(x: m.x + r, y: m.y))
                    d.addLine(to: CGPoint(x: m.x, y: m.y + r)); d.addLine(to: CGPoint(x: m.x - r, y: m.y)); d.closeSubpath()
                    if c.picked.contains("mid:" + cv.id) { ctx.fill(d, with: .color(Theme.selected)) }
                    else { ctx.stroke(d, with: .color((cv.projected ? Self.projected : ink).opacity(0.8)), lineWidth: 1.2) }
                }
            }
            for (i, pt) in sketch.points.enumerated() {
                let s = c.screen(pt)
                if i < sketch.pointIDs.count, c.picked.contains(sketch.pointIDs[i]) {
                    ctx.fill(Path(ellipseIn: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12)), with: .color(Theme.selected))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: s.x - 2.5, y: s.y - 2.5, width: 5, height: 5)), with: .color(ink))
                }
            }

            // Horizontal / vertical constraints: a small glyph beside the line.
            for (i, vertical) in sketch.alignments where i < sketch.curves.count {
                let cv = sketch.curves[i]
                guard cv.kind == .line, cv.length * c.ppm > 60 else { continue }
                let m = c.screen((cv.start + cv.end) / 2)
                let at = vertical ? CGPoint(x: m.x - 12, y: m.y) : CGPoint(x: m.x, y: m.y - 11)
                ctx.draw(Text(vertical ? "V" : "H").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary), at: at)
            }

            // Other constraints: glyphs along each curve, after any H/V one.
            var placed: [Int: Int] = [:]
            for (i, _) in sketch.alignments { placed[i, default: 0] += 1 }
            for (i, text) in sketch.glyphs where i < sketch.curves.count {
                let cv = sketch.curves[i]
                let k = placed[i, default: 0]; placed[i] = k + 1
                let base: CGPoint
                switch cv.kind {
                case .line:
                    guard cv.length * c.ppm > 40 else { continue }
                    let m = c.screen((cv.start + cv.end) / 2); base = CGPoint(x: m.x + 12, y: m.y + 11)
                case .circle, .arc:
                    let o = c.screen(cv.center); base = CGPoint(x: o.x, y: o.y - cv.radius * c.ppm - 10)
                case .other: continue
                }
                ctx.draw(Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary),
                         at: CGPoint(x: base.x + CGFloat(k) * 11, y: base.y))
            }

            // Dimensions
            let dim = Theme.accent
            for m in c.dimensionMarks(sketch) {
                let color = m.editable ? dim : Color.secondary
                ctx.stroke(m.path, with: .color(color.opacity(0.85)), lineWidth: 1)
                let t = ctx.resolve(Text(m.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(color))
                let sz = t.measure(in: CGSize(width: 400, height: 40))
                let box = CGRect(x: m.label.x - sz.width / 2 - 6, y: m.label.y - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6)
                ctx.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(ground))
                ctx.stroke(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(color.opacity(m.editable ? 0.5 : 0.25)), lineWidth: 1)
                ctx.draw(t, at: m.label)
            }

            // In progress
            let pending = Color.accentColor
            if !c.chain.isEmpty {
                var p = Path()
                p.move(to: c.screen(c.chain[0]))
                for q in c.chain.dropFirst() { p.addLine(to: c.screen(q)) }
                if let h = c.hover { p.addLine(to: c.screen(h)) }
                ctx.stroke(p, with: .color(pending), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                for q in c.chain { let s = c.screen(q); ctx.fill(Path(ellipseIn: CGRect(x: s.x - 4, y: s.y - 4, width: 8, height: 8)), with: .color(pending)) }
                if let h = c.hover, let last = c.chain.last { label(&ctx, String(format: "%.1f mm", simd_distance(last, h)), at: c.screen(h)) }
            }
            if let (a, b) = c.drag {
                var p = Path()
                if c.tool == .circle {
                    let r = simd_distance(a, b) * c.ppm, o = c.screen(a)
                    p.addEllipse(in: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r))
                    label(&ctx, String(format: "⌀ %.1f mm", 2 * simd_distance(a, b)), at: c.screen(b))
                } else {
                    let sa = c.screen(a), sb = c.screen(b)
                    p.addRect(CGRect(x: min(sa.x, sb.x), y: min(sa.y, sb.y), width: abs(sb.x - sa.x), height: abs(sb.y - sa.y)))
                    label(&ctx, String(format: "%.1f × %.1f mm", abs(b.x - a.x), abs(b.y - a.y)), at: sb)
                }
                ctx.stroke(p, with: .color(pending), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    static let projected = Color.purple

    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint) {
        ctx.draw(Text(text).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: p.x + 14, y: p.y - 16), anchor: .leading)
    }
}

/// Touch handling for the sketch editor: one finger draws with the current tool, two fingers
/// pan, pinch zooms.
struct SketchTouchLayer: UIViewRepresentable {
    let controller: SketchController
    let sketch: Sketch
    var commitChain: (_ points: [SIMD2<Double>], _ closed: Bool) -> Void
    var commitRect: (SIMD2<Double>, SIMD2<Double>) -> Void
    var commitCircle: (SIMD2<Double>, Double) -> Void
    /// Project tool: the model edge or face under a point of this view goes into the sketch.
    var project: (CGPoint, UIView) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let draw = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.draw(_:)))
        draw.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pan.delegate = c; pinch.delegate = c; draw.delegate = c
        c.drawGesture = draw
        [draw, tap, pan, pinch].forEach(v.addGestureRecognizer)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SketchTouchLayer
        private var lastPan = CGPoint.zero
        weak var drawGesture: UIPanGestureRecognizer?
        /// The current one-finger stroke started a new line chain (undone if it turns into a pan).
        private var strokeStartedChain = false
        /// Where the latest finger went down (a pan only begins after it has moved a little).
        private var down: CGPoint?

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g.numberOfTouches == 0 { down = touch.location(in: g.view) }
            return true
        }
        init(_ p: SketchTouchLayer) { parent = p }
        var c: SketchController { parent.controller }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer || g is UIPanGestureRecognizer) && (o is UIPinchGestureRecognizer || o is UIPanGestureRecognizer)
                && (g.numberOfTouches > 1 || o.numberOfTouches > 1)
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            let at = g.location(in: g.view)
            if c.chain.isEmpty, let m = c.dimension(at: at, in: parent.sketch) {
                c.editingDimension = m
                return
            }
            switch c.tool {
            case .line:
                let p = c.snapped(at)
                if c.chain.count >= 3, simd_distance(p, c.chain[0]) * c.ppm < 14 {
                    parent.commitChain(c.chain, true); c.chain = []; c.hover = nil
                } else if c.chain.last != p {
                    c.chain.append(p); c.hover = nil
                }
            case .select:
                // Points (ends, centres, the origin) win over line middles, which win over the
                // curves through them; the sketch's axes come last.
                let raw = c.sketchPoint(at), sk = parent.sketch
                let point = sk.points.indices.filter { $0 < sk.pointIDs.count }
                    .map { (sk.pointIDs[$0], simd_distance(raw, sk.points[$0]) * c.ppm) }
                    .filter { $0.1 < 14 }.min { $0.1 < $1.1 }
                let mid = sk.curves.filter { $0.kind == .line && $0.length * c.ppm > 30 }
                    .map { ("mid:" + $0.id, simd_distance(raw, ($0.start + $0.end) / 2) * c.ppm) }
                    .filter { $0.1 < 12 }.min { $0.1 < $1.1 }
                let curve = sk.curves.map { ($0.id, distance(raw, $0) * c.ppm) }.filter { $0.1 < 16 }.min { $0.1 < $1.1 }
                let axis = [("x", abs(raw.y) * c.ppm), ("y", abs(raw.x) * c.ppm)].filter { $0.1 < 12 }.min { $0.1 < $1.1 }
                if let id = point?.0 ?? mid?.0 ?? curve?.0 ?? axis?.0 { c.togglePick(id) } else { c.picked = [] }
            case .project:
                if let v = g.view { parent.project(at, v) }
            default: break
            }
        }

        @objc func draw(_ g: UIPanGestureRecognizer) {
            // A pan is recognised after the finger has moved a little; start where it went down.
            let at = g.state == .began ? (down ?? g.location(in: g.view)) : g.location(in: g.view)
            let p = c.snapped(at)
            switch c.tool {
            case .rectangle, .circle:
                switch g.state {
                case .began: c.drag = (p, p)
                case .changed: if let d = c.drag { c.drag = (d.0, p) }
                case .ended:
                    if let (a, b) = c.drag {
                        if c.tool == .rectangle, abs(b.x - a.x) > 1e-6, abs(b.y - a.y) > 1e-6 { parent.commitRect(a, b) }
                        if c.tool == .circle, simd_distance(a, b) > 1e-6 { parent.commitCircle(a, simd_distance(a, b)) }
                    }
                    c.drag = nil
                default: c.drag = nil
                }
            case .line:
                // Drag to aim the next segment; lift to place its end.
                switch g.state {
                case .began, .changed:
                    if c.chain.isEmpty, g.state == .began { c.chain = [p]; strokeStartedChain = true } else { c.hover = p }
                case .ended:
                    if let h = c.hover, c.chain.last != h {
                        if c.chain.count >= 3, simd_distance(h, c.chain[0]) * c.ppm < 14 {
                            parent.commitChain(c.chain, true); c.chain = []
                        } else { c.chain.append(h) }
                    }
                    c.hover = nil
                    strokeStartedChain = false
                default:
                    c.hover = nil
                    if strokeStartedChain { c.chain = [] }
                    strokeStartedChain = false
                }
            case .select, .project: break
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            if g.state == .began {
                lastPan = .zero
                // A second finger landed: this is a pan, not a stroke with the tool.
                if let d = drawGesture, d.state == .began || d.state == .changed { d.isEnabled = false; d.isEnabled = true }
            }
            let d = CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y)
            lastPan = t
            c.center -= SIMD2(d.x / c.ppm, -d.y / c.ppm)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed || g.state == .began else { return }
            let at = g.location(in: g.view)
            let before = c.sketchPoint(at)
            c.ppm = min(max(c.ppm * g.scale, 0.02), 400)
            g.scale = 1
            let after = c.sketchPoint(at)
            c.center += before - after
        }

        private func distance(_ p: SIMD2<Double>, _ cv: Sketch.Curve) -> Double {
            switch cv.kind {
            case .circle, .arc: return abs(simd_distance(p, cv.center) - cv.radius)
            default:
                let d = cv.end - cv.start, l2 = simd_length_squared(d)
                let t = l2 == 0 ? 0 : max(0, min(1, simd_dot(p - cv.start, d) / l2))
                return simd_distance(p, cv.start + d * t)
            }
        }
    }
}

/// The sketch editor's toolbar (in place of the operations bar while a sketch is open).
struct SketchBar: View {
    let design: DesignModel
    let sketch: Sketch
    @Bindable var controller: SketchController
    /// What the Dimension alert sets: the picked entities and the alert's title.
    @State private var dimensioning: (entities: [String], title: String)?
    @State private var dimText = ""
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 4) {
            // Cancel and Finish at opposite ends, the tools between them.
            Button { Task { await design.cancelSketch() } } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36).background(Color.primary.opacity(0.06), in: .circle)
            }
            .buttonStyle(OpButtonStyle(name: "Cancel sketch", highlight: false))
            .accessibilityLabel("Cancel sketch")
            Divider().frame(height: 28)
            ForEach(SketchController.Tool.allCases) { t in
                Button { controller.tool = t } label: {
                    Image(systemName: t.symbol).font(.system(size: 18)).frame(width: 38, height: 44)
                        .background(controller.tool == t ? Theme.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 16))
                        .foregroundStyle(controller.tool == t ? Theme.accent : .primary)
                }
                .buttonStyle(OpButtonStyle(name: t.label, highlight: false))
                .accessibilityLabel(t.label)
            }
            // Construction mode: what's drawn next is reference geometry.
            Button { controller.construction.toggle() } label: {
                Image(systemName: "square.dashed").font(.system(size: 18)).frame(width: 38, height: 44)
                    .background(controller.construction ? Theme.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 16))
                    .foregroundStyle(controller.construction ? Theme.accent : .primary)
            }
            .buttonStyle(OpButtonStyle(name: "Construction", highlight: false))
            .accessibilityLabel("Construction geometry")
            .accessibilityValue(controller.construction ? "On" : "Off")
            Divider().frame(height: 28)
            if controller.tool == .line && controller.chain.count >= 2 {
                Button("Done") {
                    let pts = controller.chain
                    controller.chain = []
                    let construction = controller.construction
                    Task { await design.addPolyline(pts, closed: false, construction: construction) }
                }
                .font(.subheadline.weight(.semibold))
            }
            Button { startDimension() } label: { Image(systemName: "ruler").frame(width: 36, height: 44) }
                .buttonStyle(OpButtonStyle(name: "Dimension", highlight: false))
                .disabled(!canDimension).accessibilityLabel("Dimension")
            Menu {
                let rules = self.rules
                if rules.isEmpty {
                    Text(controller.picked.isEmpty ? "Pick points, line middles, curves or axes with Select." : "Nothing to constrain between these.")
                }
                ForEach(rules) { r in
                    Button(r.title, systemImage: r.symbol) {
                        controller.picked = []
                        Task { await design.sketchCommand(r.command, r.params) }
                    }
                }
            } label: { Image(systemName: "link").frame(width: 36, height: 44) }
                .accessibilityLabel("Constrain")
            Button {
                let ids = deletable; controller.picked = []
                Task { await design.deleteSketchCurves(ids) }
            } label: { Image(systemName: "trash").frame(width: 36, height: 44) }
                .buttonStyle(OpButtonStyle(name: "Delete", highlight: false))
                .disabled(deletable.isEmpty).accessibilityLabel("Delete")
            Divider().frame(height: 28)
            Button { Task { await design.finishSketch() } } label: {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Theme.accent, in: .circle)
            }
            .buttonStyle(OpButtonStyle(name: "Finish sketch", highlight: false))
            .accessibilityLabel("Finish sketch")
        }
        .tint(.primary)
        .padding(.horizontal, 10)
        .frame(height: 56)
        .glassEffect(in: .capsule)
        .overlay(alignment: .topLeading) {
            // Why the last sketch change was refused (an over-constraint, a conflict…).
            if let e = design.error {
                Text(e).font(.caption).foregroundStyle(Theme.conflict).lineLimit(3)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(in: .rect(cornerRadius: 14))
                    .frame(maxWidth: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .onTapGesture { design.error = nil }
            }
        }
        .alert(dimensioning?.title ?? "Dimension", isPresented: Binding(get: { dimensioning != nil }, set: { if !$0 { dimensioning = nil } })) {
            TextField("e.g. 40, plate_w / 2, or width = 40", text: $dimText)
            Button("Cancel", role: .cancel) { dimensioning = nil }
            Button("Set") {
                if let d = dimensioning {
                    let v = dimText
                    controller.picked = []
                    Task { await design.dimension(entities: d.entities, value: v) }
                }
                dimensioning = nil
            }
        } message: {
            Text(dimensioning?.title == "Angle"
                 ? "Degrees, an expression, or name = value to make a parameter."
                 : "A number in mm, an expression, or name = value to make a parameter.")
        }
        .alert("Change dimension", isPresented: Binding(get: { controller.editingDimension != nil }, set: { if !$0 { controller.editingDimension = nil } })) {
            TextField("e.g. 40 or plate_w / 2", text: $editText)
            Button("Cancel", role: .cancel) { controller.editingDimension = nil }
            Button("Set") {
                if let m = controller.editingDimension, let param = m.param {
                    let v = editText
                    Task { await design.setDimension(param, to: v) }
                }
                controller.editingDimension = nil
            }
        } message: {
            Text("A number in mm, or an expression using parameters.")
        }
        .onChange(of: controller.editingDimension?.id) { _, id in
            if id != nil { editText = controller.editingDimension?.expression ?? "" }
        }
    }

    private var pickedCurves: [Sketch.Curve] { controller.picked.compactMap { id in sketch.curves.first { $0.id == id } } }

    /// Picked curves and points that `sketch.delete` takes (not line middles or axes).
    private var deletable: [String] {
        controller.picked.filter { id in !id.hasPrefix("mid:") && id != "x" && id != "y" && id != "origin" }
    }

    /// One line or circle (its length or diameter), or any two picked things (between them).
    private var canDimension: Bool {
        if controller.picked.count == 2 { return !controller.picked.allSatisfy { $0 == "x" || $0 == "y" } }
        guard controller.picked.count == 1, let cv = pickedCurves.first else { return false }
        return cv.kind == .line || cv.kind == .circle || cv.kind == .arc
    }

    private enum Item { case point(SIMD2<Double>), line(Sketch.Curve), circle(Sketch.Curve) }

    /// What a pick is: a point (a line's middle too), a line (a sketch axis too) or a circle/arc.
    private func item(_ id: String) -> Item? {
        if id.hasPrefix("mid:"), let cv = sketch.curves.first(where: { "mid:" + $0.id == id }) { return .point((cv.start + cv.end) / 2) }
        if id == "x" || id == "y" {
            var axis = Sketch.Curve(id: id, kind: .line)
            axis.end = id == "x" ? SIMD2(1, 0) : SIMD2(0, 1)
            return .line(axis)
        }
        if let cv = sketch.curves.first(where: { $0.id == id }) {
            switch cv.kind {
            case .line: return .line(cv)
            case .circle, .arc: return .circle(cv)
            case .other: return nil
            }
        }
        return sketch.pointIDs.firstIndex(of: id).flatMap { $0 < sketch.points.count ? .point(sketch.points[$0]) : nil }
    }

    // MARK: Constraints

    struct Rule: Identifiable {
        let title: String, symbol: String, command: String, params: [String: Any]
        var id: String { title }
    }

    /// A pick as a constraint operand: a line's middle is `{midpoint: line}` (SolidCraft ties a
    /// point there), everything else its id.
    private func operand(_ id: String) -> Any { id.hasPrefix("mid:") ? ["midpoint": String(id.dropFirst(4))] as [String: Any] : id }

    /// The constraints that apply to what's picked (two points, a point and a curve, two curves,
    /// two things and a line to mirror them about…), plus construction and fix for curves.
    private var rules: [Rule] {
        let ids = controller.picked
        let items = ids.compactMap(item)
        guard !ids.isEmpty, items.count == ids.count else { return [] }
        let axis = { (id: String) in id == "x" || id == "y" }
        let mid = { (id: String) in id.hasPrefix("mid:") }
        var out: [Rule] = []
        func add(_ t: String, _ s: String, _ c: String, _ p: [String: Any]) { out.append(.init(title: t, symbol: s, command: c, params: p)) }
        let pair = "sketch.constraint."
        switch ids.count {
        case 1:
            if case .line = items[0], !axis(ids[0]) {
                add("Horizontal", "arrow.left.and.right", pair + "horizontal_vertical", ["line": ids[0], "mode": "horizontal"])
                add("Vertical", "arrow.up.and.down", pair + "horizontal_vertical", ["line": ids[0], "mode": "vertical"])
            }
        case 2:
            let (a, b) = (ids[0], ids[1])
            switch (items[0], items[1]) {
            case (.point, .point):
                add("Coincident", "smallcircle.filled.circle", pair + "coincident", ["a": operand(a), "b": operand(b)])
                add("Horizontal (level)", "arrow.left.and.right", pair + "horizontal_vertical", ["points": [operand(a), operand(b)], "mode": "horizontal"])
                add("Vertical (in line)", "arrow.up.and.down", pair + "horizontal_vertical", ["points": [operand(a), operand(b)], "mode": "vertical"])
            case (.point, .line), (.line, .point):
                let (p, l) = { if case .point = items[0] { return (a, b) } else { return (b, a) } }()
                add("On line", "point.topleft.down.to.point.bottomright.curvepath", pair + "coincident", ["a": operand(p), "b": l])
                if !axis(l) && !mid(p) { add("At middle of line", "circle.and.line.horizontal", pair + "midpoint", ["a": p, "b": l]) }
            case (.point, .circle), (.circle, .point):
                let (p, cv) = { if case .point = items[0] { return (a, b) } else { return (b, a) } }()
                add("On circle", "circle.dashed", pair + "coincident", ["a": operand(p), "b": cv])
                if !mid(p) { add("At centre", "smallcircle.circle", pair + "concentric", ["a": cv, "b": p]) }
            case (.line, .line):
                add("Parallel", "equal", pair + "parallel", ["a": a, "b": b])
                add("Perpendicular", "angle", pair + "perpendicular", ["a": a, "b": b])
                add("Collinear", "line.diagonal", pair + "collinear", ["a": a, "b": b])
                if !axis(a) && !axis(b) { add("Equal length", "equal.square", pair + "equal", ["a": a, "b": b]) }
            case (.line, .circle), (.circle, .line):
                add("Tangent", "circle.bottomhalf.filled", pair + "tangent", ["a": a, "b": b])
            case (.circle, .circle):
                add("Tangent", "circle.bottomhalf.filled", pair + "tangent", ["a": a, "b": b])
                add("Concentric", "smallcircle.circle", pair + "concentric", ["a": a, "b": b])
                add("Equal radius", "equal.square", pair + "equal", ["a": a, "b": b])
            }
        case 3:
            // Two things mirrored about a line (the third pick).
            if case .line = items[2], !mid(ids[0]), !mid(ids[1]) {
                add("Symmetric about line", "arrow.left.and.right.righttriangle.left.righttriangle.right", pair + "symmetry",
                    ["a": ids[0], "b": ids[1], "line": ids[2]])
            }
        default: break
        }
        let curves = pickedCurves
        if !curves.isEmpty && curves.count == ids.count {
            let all = curves.allSatisfy(\.construction)
            add(all ? "Make normal geometry" : "Make construction", "square.dashed", "sketch.construction",
                ["curves": curves.map(\.id), "value": !all])
        }
        let fixable = ids.filter { !mid($0) && !axis($0) && $0 != "origin" }
        if fixable.count == ids.count {
            add("Fix / unfix in place", "pin", pair + "fix", ["entities": fixable])
        }
        return out
    }

    private func startDimension() {
        let ids = controller.picked
        guard canDimension else { return }
        func fmt(_ v: Double) -> String { String(format: "%g", (v * 1000).rounded() / 1000) }
        if ids.count == 1, let cv = pickedCurves.first {
            dimText = fmt(cv.kind == .line ? cv.length : cv.radius * 2)
            dimensioning = (ids, cv.kind == .line ? "Length" : "Diameter")
            return
        }
        // Two things: prefill what SolidCraft will measure between them.
        func lineDist(_ p: SIMD2<Double>, _ l: Sketch.Curve) -> Double {
            let d = l.end - l.start, n = simd_length(d)
            return n == 0 ? simd_distance(p, l.start) : abs(d.x * (p.y - l.start.y) - d.y * (p.x - l.start.x)) / n
        }
        var title = "Distance", value: Double?
        switch (item(ids[0]), item(ids[1])) {
        case let (.point(a)?, .point(b)?): value = simd_distance(a, b)
        case let (.point(p)?, .line(l)?), let (.line(l)?, .point(p)?): value = lineDist(p, l)
        case let (.point(p)?, .circle(c)?), let (.circle(c)?, .point(p)?): value = abs(simd_distance(p, c.center) - c.radius)
        case let (.line(l)?, .circle(c)?), let (.circle(c)?, .line(l)?): value = max(lineDist(c.center, l) - c.radius, 0)
        case let (.circle(a)?, .circle(b)?): value = max(simd_distance(a.center, b.center) - a.radius - b.radius, 0)
        case let (.line(a)?, .line(b)?):
            let u = simd_normalize(a.end - a.start), v = simd_normalize(b.end - b.start)
            let cross = abs(u.x * v.y - u.y * v.x)
            if cross < 1e-6 {
                value = lineDist(b.start, a)
            } else {
                title = "Angle"
                var deg = acos(min(max(abs(simd_dot(u, v)), 0), 1)) * 180 / .pi
                if deg < 1e-6 { deg = 90 }
                value = deg
            }
        default: value = nil
        }
        dimText = value.map(fmt) ?? ""
        dimensioning = (ids, title)
    }
}
