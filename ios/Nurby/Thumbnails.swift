import SceneKit
import UIKit

/// Small pictures of saved designs for the start page, rendered offscreen from the display
/// meshes whenever a design is saved. Kept in Application Support/Thumbnails, by file name.
@MainActor
enum Thumbnails {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Thumbnails")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(for design: URL) -> URL { dir.appending(path: design.lastPathComponent + ".png") }

    static func image(for design: URL) -> UIImage? { UIImage(contentsOfFile: url(for: design).path) }

    static func remove(for design: URL) { try? FileManager.default.removeItem(at: url(for: design)) }

    static func save(_ meshes: [BodyMesh], for design: URL) {
        guard !meshes.isEmpty else { remove(for: design); return }
        let scene = SCNScene()
        let root = SCNNode()
        root.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(root)
        for m in meshes { root.addChildNode(ViewportView.node(for: m, dark: false)) }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        scene.rootNode.addChildNode(camera)
        ViewportView.frame(camera: camera, meshes: meshes, margin: 0.8)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 900
        light.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        camera.addChildNode(light)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 480, height: 360), antialiasingMode: .multisampling4X)
        try? image.pngData()?.write(to: url(for: design))
    }
}
