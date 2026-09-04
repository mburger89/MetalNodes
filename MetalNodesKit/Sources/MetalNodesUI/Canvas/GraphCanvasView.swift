import SwiftUI
import MetalNodesCore

public struct GraphCanvasView: View {
    let model: EditorModel
    @State private var transform = CanvasTransform()
    @State private var anchors: [SocketRef: CGPoint] = [:]
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?

    static let contentSize: CGFloat = 4000

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        // GeometryReader decouples the viewport's reported size from `content`'s explicit
        // 4000×4000 frame: without it, the ZStack's ideal size bubbles up as 4000×4000 (a
        // plain `.frame(maxWidth: .infinity)` on the ZStack does not fix this — SwiftUI still
        // answers unconstrained ideal-size queries, which is what HSplitView's initial pane
        // sizing uses, with the child's natural size), so the HSplitView pane — and the whole
        // window — grow to fit the canvas and the visible slice lands far from its origin.
        // Pinning the ZStack to the reader's proposed size keeps the viewport at the pane's
        // actual bounds; `.clipped()` then clips the offset/scaled canvas to that viewport.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DraculaToken.background.color
                gridDots
                content
                    .frame(width: Self.contentSize, height: Self.contentSize, alignment: .topLeading)
                    .scaleEffect(transform.zoom, anchor: .topLeading)
                    .offset(transform.pan)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture)
            .simultaneousGesture(magnifyGesture)
        }
        .onPreferenceChange(SocketAnchorKey.self) { anchors = $0 }
        .onAppear { if let cam = model.viewState.cameras[.root] { transform = CanvasTransform(camera: cam) } }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            WireLayer(graph: model.document.root, anchors: anchors) { from in
                if let t = model.resolvedTypes[from.node]?.outputTypes[from.socket] {
                    return DraculaTheme.token(for: t).color
                }
                return DraculaTheme.wireDefault.color
            }
            ForEach(Array(model.document.root.nodes.values), id: \.id) { node in
                if case .builtin(let defID) = node.kind, let def = model.registry[defID] {
                    NodeView(node: node, def: def, resolved: model.resolvedTypes[node.id],
                             graph: model.document.root) { model.apply($0) }
                        .offset(x: node.position.x, y: node.position.y)
                }
            }
        }
        .coordinateSpace(.named("canvas"))
    }

    private var gridDots: some View {
        Canvas { ctx, size in
            let spacing = 24 * transform.zoom
            guard spacing >= 8 else { return }
            let ox = transform.pan.width.truncatingRemainder(dividingBy: spacing)
            let oy = transform.pan.height.truncatingRemainder(dividingBy: spacing)
            var x = ox
            while x < size.width {
                var y = oy
                while y < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(DraculaTheme.canvasGrid))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if panOrigin == nil { panOrigin = transform.pan }
                transform.pan = CGSize(width: panOrigin!.width + g.translation.width, height: panOrigin!.height + g.translation.height)
            }
            .onEnded { _ in panOrigin = nil; model.viewState.cameras[.root] = transform.camera }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if zoomOrigin == nil { zoomOrigin = transform.zoom }
                let target = zoomOrigin! * g.magnification
                transform.zoom(by: target / transform.zoom, around: g.startLocation)
            }
            .onEnded { _ in zoomOrigin = nil; model.viewState.cameras[.root] = transform.camera }
    }
}
