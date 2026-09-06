import SwiftUI
import MetalNodesCore

/// A 180×120 overview of the active graph (spec §21.6), drawn bottom-right on the canvas: node
/// frames in their category colour (accent for group instances), comment frames as outlines, and
/// the visible canvas rect as a `foreground` outline. Clicking or dragging anywhere on it re-centres
/// the canvas at that point (`CanvasRequest.centerOn`, handled by `GraphCanvasView`).
struct MinimapView: View {
    static let size = CGSize(width: 180, height: 120)

    let model: EditorModel
    /// The visible canvas rect, in canvas coordinates — the same rect `NodeGeometry.visibleNodes`
    /// culls against.
    let viewportRect: CGRect

    private var layout: MinimapLayout {
        MinimapLayout(size: Self.size, graphBounds: model.contentBounds ?? viewportRect, viewport: viewportRect)
    }

    var body: some View {
        let layout = layout
        Canvas { context, size in
            let bounds = Path(CGRect(origin: .zero, size: size))
            context.fill(bounds, with: .color(DraculaToken.background.color.opacity(0.9)))

            for node in model.graph.nodes.values {
                guard let shape = model.shape(of: node) else { continue }
                let frame = NodeGeometry.frame(for: node, shape: shape)
                let color = shape.accent.map { DraculaTheme.token(for: $0).color }
                    ?? DraculaTheme.token(for: shape.category).color
                context.fill(Path(layout.mapRect(frame)), with: .color(color))
            }
            for frame in model.graph.frames.values {
                context.stroke(Path(layout.mapRect(frame.frame)),
                               with: .color(DraculaTheme.token(for: frame.accent).color), lineWidth: 1)
            }
            context.stroke(Path(layout.mapRect(viewportRect)), with: .color(DraculaToken.foreground.color), lineWidth: 1)
            context.stroke(bounds, with: .color(DraculaToken.surface.color), lineWidth: 1)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in model.requestCanvas(.centerOn(layout.canvasPoint(g.location))) }
        )
    }
}
