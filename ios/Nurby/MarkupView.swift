import PencilKit
import SwiftUI

/// Pen markup over a frozen picture of the viewport. Draw with a finger or Apple Pencil, then
/// "Attach" hands the picture with the strokes to the agent composer.
struct MarkupView: View {
    let base: UIImage
    /// The part of the picture to keep (the area the panels leave uncovered); strokes outside it widen it.
    var crop: CGRect? = nil
    var done: (UIImage?) -> Void

    @State private var canvas = PKCanvasView()
    @State private var color: Color = .red
    @State private var width: CGFloat = 5
    @State private var eraser = false
    @State private var strokes = 0

    private static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    var body: some View {
        ZStack {
            Image(uiImage: base).resizable().ignoresSafeArea()
            PenCanvas(canvas: canvas, tool: tool) { strokes = canvas.drawing.strokes.count }
                .ignoresSafeArea()
            VStack {
                Text("Draw on the view to show the agent what you mean")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).frame(height: 40)
                    .glassEffect(in: .capsule)
                    .padding(.top, 12)
                Spacer()
                toolbar.padding(.bottom, 14)
            }
        }
    }

    private var tool: PKTool {
        eraser ? PKEraserTool(.vector) : PKInkingTool(.pen, color: UIColor(color), width: width)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { done(nil) } label: { Image(systemName: "xmark").frame(width: 40, height: 44) }
                .accessibilityLabel("Cancel markup")
            Divider().frame(height: 28)
            ForEach(Self.colors, id: \.self) { c in
                Button { color = c; eraser = false } label: {
                    Circle().fill(c).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(!eraser && color == c ? Theme.accent : .clear, lineWidth: 2.5))
                        .frame(width: 36, height: 44)
                }
            }
            Divider().frame(height: 28)
            Menu {
                Picker("Width", selection: $width) {
                    Text("Fine").tag(CGFloat(2))
                    Text("Medium").tag(CGFloat(5))
                    Text("Bold").tag(CGFloat(10))
                }
            } label: {
                Image(systemName: "lineweight").frame(width: 40, height: 44)
            }
            .accessibilityLabel("Pen width")
            Button { eraser.toggle() } label: {
                Image(systemName: "eraser").frame(width: 40, height: 44)
                    .foregroundStyle(eraser ? Theme.accent : .primary)
            }
            .accessibilityLabel("Eraser")
            Button { canvas.undoManager?.undo(); strokes = canvas.drawing.strokes.count } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 44)
            }
            .disabled(strokes == 0)
            .accessibilityLabel("Undo stroke")
            Button { canvas.drawing = PKDrawing(); strokes = 0 } label: {
                Image(systemName: "trash").frame(width: 40, height: 44)
            }
            .disabled(strokes == 0)
            .accessibilityLabel("Clear markup")
            Button(action: attach) {
                Label("Attach", systemImage: "paperclip")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 36).background(Theme.accent, in: .capsule)
            }
            .padding(.leading, 4)
        }
        .tint(.primary)
        .padding(.horizontal, 10)
        .frame(height: 56)
        .glassEffect(in: .capsule)
    }

    /// The frozen view with the strokes drawn over it, cropped to the uncovered area plus the strokes.
    private func attach() {
        let full = CGRect(origin: .zero, size: base.size)
        var keep = crop ?? full
        let ink = canvas.drawing.bounds
        if !ink.isEmpty { keep = keep.union(ink.insetBy(dx: -40, dy: -40)) }
        keep = keep.intersection(full).integral
        if keep.isEmpty { keep = full }
        let strokes = canvas.drawing.image(from: full, scale: base.scale)
        done(Self.crop(composite: [base, strokes], size: base.size, scale: base.scale, to: keep))
    }

    /// Draws the layers at full size and keeps only `rect` of them.
    static func crop(composite layers: [UIImage], size: CGSize, scale: CGFloat, to rect: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            for l in layers { l.draw(in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: size)) }
        }
    }
}

/// A transparent PencilKit canvas that takes finger and pencil input.
private struct PenCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let tool: PKTool
    var changed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = context.coordinator
        canvas.tool = tool
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        view.tool = tool
        context.coordinator.changed = changed
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var changed: () -> Void = {}
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { changed() }
    }
}
