import SceneKit
import SwiftUI

/// The 3D viewport: every visible body's display mesh with its feature edges. Drag to orbit
/// (turntable, like Blender), two fingers to pan, pinch to zoom (the camera is driven by the
/// coordinator, not SceneKit's controller, so `NavigationGizmo` can turn it too); tap a face or edge to select it (faces green, edges orange), tap it again
/// to deselect, tap empty space to clear. SolidCraft is Z-up in millimetres; SceneKit is Y-up.
struct ViewportView: UIViewRepresentable {
    let meshes: [BodyMesh]
    let revision: Int
    let selection: [DesignModel.Pick]
    /// Faces made by the feature being edited (tinted blue, under the selection).
    var affected: [DesignModel.Pick] = []
    /// The open sketch: the camera looks straight at its plane, orthographic, centred on
    /// `sketchCenter` at `sketchPPM` screen points per mm (the sketch editor draws on top).
    var sketch: Sketch? = nil
    var sketchCenter = SIMD2<Double>(0, 0)
    var sketchPPM = 4.0
    /// The share of the view's width the floating panels leave uncovered (the part is fitted to it).
    var visibleWidth: CGFloat = 1
    /// How far the view extends past the screen's left edge (it is centred on the open area);
    /// that much on each side is out of sight or under the sidebar.
    var offscreen: CGFloat = 0
    /// The same past the screen's top edge (panels docked along the bottom): that much at the top
    /// and bottom is out of sight or under the panels.
    var offscreenBottom: CGFloat = 0
    /// Changes when the panels move (side ↔ bottom); the part is framed again for the new open area.
    var layoutKey = 0
    /// Lets the studio grab a picture of the view (for the agent and pen markup).
    var handle: ViewportHandle? = nil
    /// The view's real size (the sketch overlay must use the same frame as the camera).
    var onResize: ((CGSize) -> Void)? = nil
    /// A sketch's regions an extrude panel is choosing from: drawn on the sketch's plane over
    /// everything (chosen ones blue); a tap inside one calls `onRegion` with its index.
    var regions: RegionPick? = nil
    var onRegion: ((Int) -> Void)? = nil
    var onPick: (DesignModel.Pick?) -> Void
    @Environment(\.colorScheme) private var scheme

    static let bodyCategory = 1
    static let pickGreen = UIColor.systemGreen
    static let affectedBlue = UIColor.systemBlue.withAlphaComponent(0.45)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SizedSCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        let scene = SCNScene()
        view.scene = scene

        let root = SCNNode()
        root.eulerAngles.x = -.pi / 2   // Z-up model into Y-up scene
        scene.rootNode.addChildNode(root)
        let affected = SCNNode()
        root.addChildNode(affected)
        let highlight = SCNNode()
        root.addChildNode(highlight)
        let bodies = SCNNode()
        root.addChildNode(bodies)
        let regions = SCNNode()
        root.addChildNode(regions)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 35
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        camera.addChildNode(key)   // light follows the camera, like a CAD headlight

        let c = context.coordinator
        c.view = view
        c.root = root
        c.bodies = bodies
        c.highlight = highlight
        c.affected = affected
        c.regionsNode = regions
        c.camera = camera
        handle?.view = view
        handle?.coordinator = c
        c.handle = handle
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        let orbit = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.orbitPan(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:)))
        for g in [orbit, pan, pinch] as [UIGestureRecognizer] { g.delegate = c }
        [tap, orbit, pan, pinch].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.onPick = onPick
        c.onRegion = onRegion
        if c.regionPick != regions || c.regionsDark != (scheme == .dark) {
            c.regionPick = regions
            c.regionsDark = scheme == .dark
            c.regionsNode?.childNodes.forEach { $0.removeFromParentNode() }
            if let regions { c.regionsNode?.addChildNode(Self.regionsNode(regions, dark: scheme == .dark)) }
        }
        (view as? SizedSCNView)?.onResize = onResize
        var reframe = false
        var later = false
        if c.layoutKey != layoutKey {
            // The view takes its new size in this layout pass: frame once it has.
            reframe = c.layoutKey != nil
            later = true
            c.layoutKey = layoutKey
        }
        if sketch == nil, c.inSketch {
            c.inSketch = false
            (view.pointOfView ?? c.camera)?.camera?.usesOrthographicProjection = false
            reframe = true
        }
        if c.revision != revision || c.dark != (scheme == .dark) {
            let firstModel = c.empty && !meshes.isEmpty
            c.revision = revision
            c.dark = scheme == .dark
            c.meshes = meshes
            c.bodies?.childNodes.forEach { $0.removeFromParentNode() }
            for m in meshes { c.bodies?.addChildNode(Self.node(for: m, dark: c.dark)) }
            c.bodies?.addChildNode(Self.grid(dark: c.dark))
            reframe = reframe || firstModel || c.empty
            c.empty = meshes.isEmpty
            c.shown = []
            c.shownAffected = []
            c.highlight?.childNodes.forEach { $0.removeFromParentNode() }   // picks renumber with the model
            c.affected?.childNodes.forEach { $0.removeFromParentNode() }
        }
        if let sketch {
            c.inSketch = true
            if let root = c.root, let camera = view.pointOfView ?? c.camera {
                Self.aim(camera, root: root, at: sketch, center: sketchCenter, ppm: sketchPPM, height: view.bounds.height)
            }
        } else if reframe {
            let meshes = meshes, offscreen = offscreen, below = offscreenBottom, share = visibleWidth
            // Before the first layout the view has no size yet; frame once it has.
            let go = { [weak view] in
                guard let view, let camera = view.pointOfView else { return }
                let b = view.bounds.size
                let visible = b.width > 0 ? (b.width - offscreen * 2) / b.width * share : share
                let tall = b.height > 0 ? max(b.height - below * 2, 1) / b.height : 1
                let aspect = b.height > 0 ? min(Float(b.width / b.height) * Float(min(max(visible, 0.1), 1)), Float(tall)) : 0.75
                let center = Self.frame(camera: camera, meshes: meshes, margin: 1.2, aspect: aspect)
                c.adopt(target: center)
            }
            if view.bounds.isEmpty || later { DispatchQueue.main.async(execute: go) } else { go() }
        }
        if c.shown != selection {
            c.shown = selection
            c.highlight?.childNodes.forEach { $0.removeFromParentNode() }
            for p in selection {
                if let m = meshes.first(where: { $0.name == p.body }), let n = Self.highlight(p, in: m) { c.highlight?.addChildNode(n) }
            }
        }
        if c.shownAffected != affected {
            c.shownAffected = affected
            c.affected?.childNodes.forEach { $0.removeFromParentNode() }
            for p in affected {
                if let m = meshes.first(where: { $0.name == p.body }), let n = Self.highlight(p, in: m, color: Self.affectedBlue) { c.affected?.addChildNode(n) }
            }
        }
    }

    // MARK: Picking

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: SCNView?
        var layoutKey: Int?
        var root: SCNNode?, bodies: SCNNode?, highlight: SCNNode?, affected: SCNNode?, camera: SCNNode?, regionsNode: SCNNode?
        var regionPick: RegionPick?
        var regionsDark = false
        var onRegion: ((Int) -> Void)?
        var shownAffected: [DesignModel.Pick] = []
        var meshes: [BodyMesh] = []
        var revision = -1
        var dark = false
        var empty = true
        var shown: [DesignModel.Pick] = []
        var inSketch = false {
            didSet { if inSketch { stopMotion() } }
        }
        var onPick: ((DesignModel.Pick?) -> Void)?
        weak var handle: ViewportHandle?

        // MARK: Camera
        // The camera orbits `target` at `distance`; `orientation` is its rotation (it looks down
        // its local −Z with +Y up, as SceneKit cameras do).
        var target = SIMD3<Float>(0, 0, 0)
        var distance: Float = 200
        var orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        private var link: CADisplayLink?
        private var tick: ((Float) -> Bool)?
        private var lastTick: CFTimeInterval = 0
        private var lastPan = CGPoint.zero, lastPan2 = CGPoint.zero

        /// Take over wherever the camera now is (after `frame`), looking at `target`.
        func adopt(target t: SIMD3<Float>) {
            guard let camera = view?.pointOfView else { return }
            stopMotion()
            target = t
            distance = max(simd_length(camera.simdPosition - t), 0.01)
            orientation = camera.simdOrientation
            apply(publish: false)
            // Called while SwiftUI updates the view: tell the gizmo afterwards.
            let q = orientation
            DispatchQueue.main.async { [weak self] in self?.handle?.orientation = q }
        }

        func apply(publish: Bool = true) {
            guard !inSketch, let camera = view?.pointOfView else { return }
            orientation = simd_normalize(orientation)
            camera.simdOrientation = orientation
            camera.simdPosition = target + orientation.act(SIMD3(0, 0, 1)) * distance
            camera.camera?.zNear = Double(max(distance / 1000, 0.01))
            camera.camera?.zFar = Double(max(distance * 20, 2000))
            if publish { handle?.orientation = orientation }
        }

        /// Turntable orbit: sideways turns about the world's up (model Z), up/down tilts about
        /// the camera's own right axis. Points of finger travel.
        func orbit(dx: CGFloat, dy: CGFloat) {
            let k: Float = 0.008
            orientation = simd_quatf(angle: -Float(dx) * k, axis: SIMD3(0, 1, 0)) * orientation
            orientation = orientation * simd_quatf(angle: -Float(dy) * k, axis: SIMD3(1, 0, 0))
            apply()
        }

        /// Move the target with the fingers (the model follows them).
        func pan(dx: CGFloat, dy: CGFloat) {
            guard let view, view.bounds.height > 0 else { return }
            let fov = Float(view.pointOfView?.camera?.fieldOfView ?? 35) * .pi / 180
            let perPoint = 2 * distance * tan(fov / 2) / Float(view.bounds.height)
            let right = orientation.act(SIMD3(1, 0, 0)), up = orientation.act(SIMD3(0, 1, 0))
            target += (-right * Float(dx) + up * Float(dy)) * perPoint
            apply()
        }

        /// Look along `-dir` (scene space) at the target, with `up` as the screen's up.
        func look(from dir: SIMD3<Float>, up: SIMD3<Float>, animated: Bool = true) {
            let back = simd_normalize(dir)
            var u = up - back * simd_dot(up, back)
            if simd_length(u) < 1e-4 { u = orientation.act(SIMD3(0, 1, 0)) - back * simd_dot(orientation.act(SIMD3(0, 1, 0)), back) }
            if simd_length(u) < 1e-4 { u = SIMD3(0, 0, -1) }
            u = simd_normalize(u)
            let right = simd_cross(u, back)
            let goal = simd_quatf(simd_float3x3(right, u, back))
            turn(to: goal, animated: animated)
        }

        func turn(to goal: simd_quatf, animated: Bool) {
            stopMotion()
            guard animated else { orientation = goal; apply(); return }
            var start = orientation
            if simd_dot(start.vector, goal.vector) < 0 { start = simd_quatf(vector: -start.vector) }
            var t: Float = 0
            run { dt in
                t = min(t + dt / 0.32, 1)
                let e = 1 - pow(1 - t, 3)
                self.orientation = simd_slerp(start, goal, e)
                self.apply()
                return t < 1
            }
        }

        /// The scene direction of the model's axis `axis` (0 x, 1 y, 2 z), signed.
        func sceneAxis(_ axis: Int, _ sign: Float) -> SIMD3<Float> {
            var v = SIMD3<Float>(0, 0, 0); v[axis] = sign
            return root.map { $0.simdConvertVector(v, to: nil) } ?? v
        }

        /// Snap to looking along a model axis (Blender's gizmo): top/bottom keep model +Y up,
        /// the others keep model +Z up. Tapping the view it is already in flips to the opposite.
        func snap(axis: Int, sign: Float) {
            var s = sign
            let back = orientation.act(SIMD3(0, 0, 1))
            if simd_dot(back, sceneAxis(axis, s)) > 0.9999 { s = -s }
            let up = axis == 2 ? sceneAxis(1, s > 0 ? 1 : -1) : sceneAxis(2, 1)
            look(from: sceneAxis(axis, s), up: up)
        }

        /// Look square onto a face: the first selected face, else the face under the middle of
        /// the view; with neither, the nearest axis view.
        func alignNormal() {
            guard let view, let root else { return }
            var normal: SIMD3<Float>?
            if let p = shown.first(where: { $0.kind == .face }), let m = meshes.first(where: { $0.name == p.body }) {
                normal = Self.faceNormal(p.index, in: m)
            } else {
                let mid = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                let hits = view.hitTest(mid, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .categoryBitMask: ViewportView.bodyCategory])
                if let hit = hits.first(where: { h in meshes.contains { $0.name == h.node.name } }),
                   let m = meshes.first(where: { $0.name == hit.node.name }), hit.faceIndex < m.triangleFaces.count {
                    normal = Self.faceNormal(m.triangleFaces[hit.faceIndex], in: m)
                }
            }
            let back = orientation.act(SIMD3(0, 0, 1))
            if var n = normal.map({ root.simdConvertVector($0, to: nil) }), simd_length(n) > 1e-4 {
                n = simd_normalize(n)
                look(from: n, up: orientation.act(SIMD3(0, 1, 0)))
            } else {
                // Nearest axis view.
                var best = (axis: 2, sign: Float(1), dot: -Float.infinity)
                for a in 0..<3 { for sg in [Float(1), -1] { let d = simd_dot(back, sceneAxis(a, sg)); if d > best.dot { best = (a, sg, d) } } }
                look(from: sceneAxis(best.axis, best.sign), up: best.axis == 2 ? sceneAxis(1, best.sign) : sceneAxis(2, 1))
            }
        }

        /// A face's mean normal from its vertex normals (model space).
        static func faceNormal(_ face: UInt32, in m: BodyMesh) -> SIMD3<Float>? {
            var sum = SIMD3<Float>(0, 0, 0)
            for t in 0..<m.triangleFaces.count where m.triangleFaces[t] == face {
                for k in 0..<3 {
                    let v = Int(m.indices[t * 3 + k]) * 3
                    guard v + 2 < m.normals.count else { continue }
                    sum += SIMD3(m.normals[v], m.normals[v + 1], m.normals[v + 2])
                }
            }
            return simd_length(sum) > 1e-6 ? simd_normalize(sum) : nil
        }

        private func run(_ f: @escaping (Float) -> Bool) {
            tick = f
            lastTick = CACurrentMediaTime()
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(step))
                l.add(to: .main, forMode: .common)
                link = l
            }
        }

        func stopMotion() { link?.invalidate(); link = nil; tick = nil }

        @objc private func step(_ l: CADisplayLink) {
            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastTick, 1.0 / 20))
            lastTick = now
            if tick?(dt) != true { stopMotion() }
        }

        @objc func orbitPan(_ g: UIPanGestureRecognizer) {
            guard !inSketch else { return }
            let t = g.translation(in: g.view)
            switch g.state {
            case .began: stopMotion(); lastPan = .zero; fallthrough
            case .changed:
                orbit(dx: t.x - lastPan.x, dy: t.y - lastPan.y); lastPan = t
            case .ended:
                var v = g.velocity(in: g.view)
                guard hypot(v.x, v.y) > 120 else { return }
                run { dt in
                    self.orbit(dx: v.x * CGFloat(dt), dy: v.y * CGFloat(dt))
                    let decay = CGFloat(pow(0.02, dt))
                    v.x *= decay; v.y *= decay
                    return hypot(v.x, v.y) > 8
                }
            default: break
            }
        }

        @objc func twoFingerPan(_ g: UIPanGestureRecognizer) {
            guard !inSketch else { return }
            let t = g.translation(in: g.view)
            if g.state == .began { stopMotion(); lastPan2 = .zero }
            guard g.state == .began || g.state == .changed else { return }
            pan(dx: t.x - lastPan2.x, dy: t.y - lastPan2.y)
            lastPan2 = t
        }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard !inSketch, g.state == .began || g.state == .changed, g.scale > 0 else { return }
            stopMotion()
            distance = min(max(distance / Float(g.scale), 0.5), 50_000)
            g.scale = 1
            apply()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            let two = { (r: UIGestureRecognizer) in r is UIPinchGestureRecognizer || ((r as? UIPanGestureRecognizer)?.minimumNumberOfTouches ?? 0) >= 2 }
            return two(g) && two(o)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view, !inSketch else { return }
            let at = g.location(in: view)
            // A tap inside one of the regions being chosen picks it (they are drawn over everything).
            if let r = regionPick, r.tappable, let p = sketchPoint(at, on: r.sketch), let hit = r.region(at: p) {
                onRegion?(hit.index)
                return
            }
            onPick?(pick(at: at))
        }

        /// Where a screen point's ray meets a sketch's plane, in sketch mm.
        func sketchPoint(_ at: CGPoint, on sk: Sketch) -> SIMD2<Double>? {
            guard let view, let root else { return nil }
            let near = root.simdConvertPosition(SIMD3(view.unprojectPoint(SCNVector3(Float(at.x), Float(at.y), 0))), from: nil)
            let far = root.simdConvertPosition(SIMD3(view.unprojectPoint(SCNVector3(Float(at.x), Float(at.y), 1))), from: nil)
            let o = SIMD3<Double>(near), d = SIMD3<Double>(far) - o
            let n = sk.normal, denom = simd_dot(d, n)
            guard abs(denom) > 1e-9 else { return nil }
            let hit = o + d * (simd_dot(sk.origin - o, n) / denom) - sk.origin
            return SIMD2(simd_dot(hit, sk.xDir), simd_dot(hit, sk.yDir))
        }

        /// The edge (within 14 pt) or face under a point of the view, if any.
        func pick(at at: CGPoint) -> DesignModel.Pick? {
            guard let view, let root else { return nil }
            let hits = view.hitTest(at, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue,
                                                  .categoryBitMask: ViewportView.bodyCategory])
            let faceHit = hits.first { hit in hit.node.name != nil && meshes.contains { $0.name == hit.node.name } }
            let hitDepth = faceHit.map { Float(view.projectPoint($0.worldCoordinates).z) }

            // An edge near the finger (within 14 pt on screen) wins over the face under it,
            // unless the edge is behind that face.
            var best: (d: CGFloat, pick: DesignModel.Pick)?
            for m in meshes {
                let e = m.edges
                for s in 0..<m.segmentEdges.count {
                    let a = SCNVector3(e[s * 6], e[s * 6 + 1], e[s * 6 + 2]), b = SCNVector3(e[s * 6 + 3], e[s * 6 + 4], e[s * 6 + 5])
                    let pa = view.projectPoint(root.convertPosition(a, to: nil)), pb = view.projectPoint(root.convertPosition(b, to: nil))
                    guard pa.z > 0, pa.z < 1, pb.z > 0, pb.z < 1 else { continue }
                    let (d, t) = Self.distance(at, CGPoint(x: CGFloat(pa.x), y: CGFloat(pa.y)), CGPoint(x: CGFloat(pb.x), y: CGFloat(pb.y)))
                    guard d < 14, d < (best?.d ?? .infinity) else { continue }
                    let depth = pa.z + (pb.z - pa.z) * Float(t)
                    if let hitDepth, depth > hitDepth + 0.0005 { continue }
                    let p = SIMD3<Float>(a.x, a.y, a.z) + (SIMD3<Float>(b.x, b.y, b.z) - SIMD3<Float>(a.x, a.y, a.z)) * Float(t)
                    best = (d, .init(kind: .edge, body: m.name, index: m.segmentEdges[s], point: p))
                }
            }
            if let best { return best.pick }

            if let hit = faceHit, let m = meshes.first(where: { $0.name == hit.node.name }), hit.faceIndex < m.triangleFaces.count {
                let local = hit.localCoordinates
                return .init(kind: .face, body: m.name, index: m.triangleFaces[hit.faceIndex], point: SIMD3(local.x, local.y, local.z))
            }
            return nil
        }

        /// Distance from `p` to segment ab, and where along it (0…1) the nearest point is.
        static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGFloat) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
            return ((x * x + y * y).squareRoot(), t)
        }
    }

    // MARK: Scene building

    /// Point a camera at the meshes from the iso direction, far enough to see all of them
    /// (`margin` > 1 leaves room). Bounds come from the mesh data (model Z-up → scene Y-up).
    /// Returns the centre it looks at.
    @discardableResult
    /// `aspect` is the usable width over the height: the narrower of it and the vertical field
    /// of view decides the distance.
    static func frame(camera: SCNNode, meshes: [BodyMesh], margin: Float, aspect: Float = 1) -> SIMD3<Float> {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for m in meshes {
            for i in stride(from: 0, to: m.positions.count - 2, by: 3) {
                let p = SIMD3(m.positions[i], m.positions[i + 2], -m.positions[i + 1])
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        var center = SIMD3<Float>(0, 0, 0), radius: Float = 60
        if lo.x.isFinite && hi.x >= lo.x {
            center = (lo + hi) / 2
            radius = max(simd_length(hi - lo) / 2, 1)
        }
        let dir = simd_normalize(SIMD3<Float>(1, 0.8, 1))
        let fov = Float(camera.camera?.fieldOfView ?? 35) * .pi / 180
        let half = atan(tan(fov / 2) * min(1, max(aspect, 0.1)))
        let dist = radius / sin(half) * margin
        camera.simdPosition = center + dir * dist
        camera.simdLook(at: center)
        camera.camera?.zNear = Double(max(dist / 1000, 0.01))
        camera.camera?.zFar = Double(dist * 20)
        return center
    }

    /// Orthographic camera square onto the sketch plane (model Z-up → scene via the root node).
    static func aim(_ camera: SCNNode, root: SCNNode, at sketch: Sketch, center: SIMD2<Double>, ppm: Double, height: CGFloat) {
        guard ppm > 0 else { return }
        let f = { (v: SIMD3<Double>) in SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }
        let target = root.simdConvertPosition(f(sketch.world(center)), to: nil)
        let normal = simd_normalize(root.simdConvertVector(f(sketch.normal), to: nil))
        let up = simd_normalize(root.simdConvertVector(f(sketch.yDir), to: nil))
        let dist: Float = 5000
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = Double(height) / 2 / ppm
        camera.camera?.zNear = 1
        camera.camera?.zFar = 20000
        camera.simdPosition = target + normal * dist
        camera.simdLook(at: target, up: up, localFront: SIMD3(0, 0, -1))
    }

    static func node(for m: BodyMesh, dark: Bool) -> SCNNode {
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: vectors(m.positions)), SCNGeometrySource(normals: vectors(m.normals))],
                              elements: [SCNGeometryElement(indices: m.indices, primitiveType: .triangles)])
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = dark ? UIColor(white: 0.78, alpha: 1) : UIColor(white: 0.86, alpha: 1)
        mat.metalness.contents = 0.05
        mat.roughness.contents = 0.55
        mat.isDoubleSided = true
        geo.materials = [mat]
        let body = SCNNode(geometry: geo)
        body.name = m.name
        body.categoryBitMask = bodyCategory

        if !m.edges.isEmpty {
            let pts = vectors(m.edges)
            let lines = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)],
                                    elements: [SCNGeometryElement(indices: Array(0..<UInt32(pts.count)), primitiveType: .line)])
            lines.materials = [constant(dark ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.2, alpha: 1))]
            let ln = SCNNode(geometry: lines)
            ln.categoryBitMask = 2
            body.addChildNode(ln)
        }
        return body
    }

    /// A picked face (its triangles, lifted a hair off the surface) or edge (its segments,
    /// drawn as thin tubes so they read on a phone): selected faces green, selected edges orange.
    static func highlight(_ p: DesignModel.Pick, in m: BodyMesh, color: UIColor = .systemGreen) -> SCNNode? {
        let green = p.kind == .edge && color == .systemGreen ? UIColor.systemOrange : color
        switch p.kind {
        case .face:
            var pos: [SCNVector3] = [], idx: [UInt32] = []
            for t in 0..<m.triangleFaces.count where m.triangleFaces[t] == p.index {
                for k in 0..<3 {
                    let v = Int(m.indices[t * 3 + k]) * 3
                    let lift: Float = color == .systemGreen ? 0.02 : 0.015
                    pos.append(SCNVector3(m.positions[v] + m.normals[v] * lift, m.positions[v + 1] + m.normals[v + 1] * lift, m.positions[v + 2] + m.normals[v + 2] * lift))
                    idx.append(UInt32(idx.count))
                }
            }
            guard !pos.isEmpty else { return nil }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos)], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
            let mat = constant(color == .systemGreen ? green.withAlphaComponent(0.8) : color)
            mat.writesToDepthBuffer = false
            mat.isDoubleSided = true
            g.materials = [mat]
            let n = SCNNode(geometry: g)
            n.categoryBitMask = 2
            return n
        case .edge:
            let parent = SCNNode()
            let e = m.edges
            var size: Float = 1
            for i in stride(from: 0, to: m.positions.count - 2, by: 3) { size = max(size, abs(m.positions[i]), abs(m.positions[i + 1]), abs(m.positions[i + 2])) }
            let radius = CGFloat(max(size * 0.004, 0.15))
            for s in 0..<m.segmentEdges.count where m.segmentEdges[s] == p.index {
                let a = SIMD3(e[s * 6], e[s * 6 + 1], e[s * 6 + 2]), b = SIMD3(e[s * 6 + 3], e[s * 6 + 4], e[s * 6 + 5])
                let len = simd_length(b - a)
                guard len > 0 else { continue }
                let tube = SCNCylinder(radius: radius, height: CGFloat(len))
                tube.radialSegmentCount = 8
                tube.materials = [constant(green)]
                let n = SCNNode(geometry: tube)
                n.simdPosition = (a + b) / 2
                n.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(b - a))
                n.categoryBitMask = 2
                parent.addChildNode(n)
            }
            return parent
        }
    }

    /// A sketch's regions on its plane: filled (chosen ones blue, the rest a faint cyan, all of
    /// them cyan while none is chosen and the extrude takes the sketch's default) with their
    /// outlines, drawn over the model so they stay visible inside a previewed extrude.
    static func regionsNode(_ r: RegionPick, dark: Bool) -> SCNNode {
        let sk = r.sketch
        let f = { (v: SIMD3<Double>) in SIMD4<Float>(Float(v.x), Float(v.y), Float(v.z), 0) }
        let parent = SCNNode()
        var o = f(sk.origin); o.w = 1
        parent.simdTransform = simd_float4x4(columns: (f(sk.xDir), f(sk.yDir), f(sk.normal), o))
        for region in r.regions {
            let path = UIBezierPath()
            for loop in [region.outer] + region.holes {
                guard let first = loop.first else { continue }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for q in loop.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
                path.close()
            }
            path.usesEvenOddFillRule = true
            let chosen = r.chosen.contains(region.index)
            let color: UIColor = chosen ? UIColor.systemBlue.withAlphaComponent(0.5)
                : UIColor.systemCyan.withAlphaComponent(r.chosen.isEmpty ? 0.28 : 0.1)
            let shape = SCNShape(path: path, extrusionDepth: 0)
            let mat = constant(color)
            mat.isDoubleSided = true
            mat.readsFromDepthBuffer = false
            mat.writesToDepthBuffer = false
            shape.materials = [mat]
            let n = SCNNode(geometry: shape)
            n.renderingOrder = 50
            n.categoryBitMask = 2
            parent.addChildNode(n)

            // Outline
            var pts: [SCNVector3] = []
            for loop in [region.outer] + region.holes {
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    pts += [SCNVector3(Float(a.x), Float(a.y), 0), SCNVector3(Float(b.x), Float(b.y), 0)]
                }
            }
            let lines = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)],
                                    elements: [SCNGeometryElement(indices: Array(0..<UInt32(pts.count)), primitiveType: .line)])
            let lm = constant(chosen ? UIColor.systemBlue : UIColor.systemCyan)
            lm.readsFromDepthBuffer = false
            lm.writesToDepthBuffer = false
            lines.materials = [lm]
            let ln = SCNNode(geometry: lines)
            ln.renderingOrder = 51
            ln.categoryBitMask = 2
            parent.addChildNode(ln)
        }
        return parent
    }

    /// A 200 mm grid on the XY plane, 10 mm cells.
    static func grid(dark: Bool) -> SCNNode {
        var pts: [SCNVector3] = []
        let half: Float = 100
        for i in stride(from: -half, through: half, by: 10) {
            pts += [SCNVector3(i, -half, 0), SCNVector3(i, half, 0), SCNVector3(-half, i, 0), SCNVector3(half, i, 0)]
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)],
                            elements: [SCNGeometryElement(indices: Array(0..<UInt32(pts.count)), primitiveType: .line)])
        let m = constant((dark ? UIColor.white : UIColor.black).withAlphaComponent(0.12))
        m.writesToDepthBuffer = false
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.name = "grid"
        n.categoryBitMask = 2
        return n
    }

    private static func vectors(_ f: [Float]) -> [SCNVector3] {
        stride(from: 0, to: f.count - 2, by: 3).map { SCNVector3(f[$0], f[$0 + 1], f[$0 + 2]) }
    }

    private static func constant(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }
}

/// A weak reference to the live SceneKit view, for snapshots, and to its camera (the
/// navigation gizmo reads `orientation` and turns the view through it).
@Observable @MainActor final class ViewportHandle {
    @ObservationIgnored weak var view: SCNView?
    @ObservationIgnored weak var coordinator: ViewportView.Coordinator?
    /// The camera's rotation in scene space (updated as it moves).
    var orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))

    func orbit(dx: CGFloat, dy: CGFloat) { coordinator?.stopMotion(); coordinator?.orbit(dx: dx, dy: dy) }
    func snap(axis: Int, sign: Float) { coordinator?.snap(axis: axis, sign: sign) }
    func alignNormal() { coordinator?.alignNormal() }
    /// The model edge or face under a point of `other` (a view drawn over this one, such as the
    /// sketch editor's touch layer), if any.
    func pick(at p: CGPoint, in other: UIView) -> DesignModel.Pick? {
        guard let view, let coordinator else { return nil }
        return coordinator.pick(at: other.convert(p, to: view))
    }
    /// The model's axis (0 x, 1 y, 2 z) in camera space: x right, y up, z towards the viewer.
    func screenAxis(_ axis: Int) -> SIMD3<Float> {
        var v = SIMD3<Float>(0, 0, 0); v[axis] = 1
        let scene = SIMD3(v.x, v.z, -v.y)   // the root node turns Z-up into Y-up
        return orientation.inverse.act(scene)
    }

    /// The view as the person sees it, on the studio's background colour.
    func snapshot(background: UIColor) -> UIImage? {
        guard let view, !view.bounds.isEmpty else { return nil }
        let shot = view.snapshot()
        let size = view.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            shot.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// An SCNView that says when its size changes.
final class SizedSCNView: SCNView {
    var onResize: ((CGSize) -> Void)?
    private var last = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != last, !bounds.isEmpty else { return }
        last = bounds.size
        let size = bounds.size, report = onResize
        DispatchQueue.main.async { report?(size) }
    }
}
