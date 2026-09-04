import SwiftUI
import MetalNodesCore

public struct GraphCanvasView: View {
    let model: EditorModel
    @State private var transform = CanvasTransform()
    @State private var anchors: [SocketRef: CGPoint] = [:]
    @State private var zoomOrigin: CGFloat?
    @State private var panOrigin: CGSize?
    @State private var marqueeStart: CGPoint?          // canvas coords
    @State private var marquee: CGRect?                // canvas coords
    @State private var spaceHeld = false
    @State private var dragOrigins: [NodeID: CGPoint] = [:]
    @FocusState private var canvasFocused: Bool

    static let contentSize: CGFloat = 4000
    static let wireHitDistance: CGFloat = 6

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        // GeometryReader decouples the viewport's reported size from `content`'s explicit 4000×4000
        // frame: without it, the ZStack's ideal size bubbles up as 4000×4000 (a plain
        // `.frame(maxWidth: .infinity)` does not fix this — SwiftUI still answers unconstrained
        // ideal-size queries with the child's natural size, which is what HSplitView's initial pane
        // sizing uses), so the pane and window grow to fit the canvas. Pinning the ZStack to the
        // reader's proposed size keeps the viewport at the pane's bounds; `.clipped()` then clips
        // the offset/scaled canvas.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DraculaToken.background.color
                gridDots
                content
                    .frame(width: Self.contentSize, height: Self.contentSize, alignment: .topLeading)
                    .scaleEffect(transform.zoom, anchor: .topLeading)
                    .offset(transform.pan)
                marqueeOverlay
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(backgroundDrag)
            .simultaneousGesture(magnifyGesture)
            .focusable()
            .focusEffectDisabled()
            .focused($canvasFocused)
            .onKeyPress(.space, phases: [.down, .up]) { press in
                spaceHeld = press.phase == .down
                return .handled
            }
            .onKeyPress(.delete) { model.deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { model.deleteSelection(); return .handled }
            .onKeyPress(.escape) { model.clearSelection(); return .handled }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                let d: CGSize = switch press.key {
                case .upArrow: CGSize(width: 0, height: -step)
                case .downArrow: CGSize(width: 0, height: step)
                case .leftArrow: CGSize(width: -step, height: 0)
                default: CGSize(width: step, height: 0)
                }
                model.nudgeSelection(by: d)
                return .handled
            }
            .onChange(of: canvasFocused) { _, focused in
                if !focused { spaceHeld = false }
            }
        }
        .onPreferenceChange(SocketAnchorKey.self) { anchors = $0 }
        .onAppear { if let cam = model.viewState.cameras[.root] { transform = CanvasTransform(camera: cam) } }
        .onAppear { canvasFocused = true }
    }

    // MARK: Content

    private var content: some View {
        ZStack(alignment: .topLeading) {
            WireLayer(graph: model.document.root, anchors: anchors, selected: model.selectedWire) { from in
                if let t = model.resolvedTypes[from.node]?.outputTypes[from.socket] {
                    return DraculaTheme.token(for: t).color
                }
                return DraculaTheme.wireDefault.color
            }
            ForEach(Array(model.document.root.nodes.values), id: \.id) { node in
                if case .builtin(let defID) = node.kind, let def = model.registry[defID] {
                    NodeView(node: node, def: def, resolved: model.resolvedTypes[node.id],
                             graph: model.document.root,
                             isSelected: model.selection.contains(node.id),
                             onChange: { model.apply($0) },
                             onSelect: { mode in canvasFocused = true; model.select(node.id, mode: mode) },
                             onDragBegan: { beginNodeDrag() },
                             onDrag: { moveSelection(by: $0) },
                             onDragEnded: { endNodeDrag() },
                             onEditing: { editing in
                                 if editing {
                                     if model.isInTransaction { model.endTransaction() }   // defensive reset
                                     model.beginTransaction("Change Value")
                                 } else {
                                     model.endTransaction()
                                 }
                             })
                        .offset(x: node.position.x, y: node.position.y)
                }
            }
        }
        .coordinateSpace(.named("canvas"))
    }

    private var marqueeOverlay: some View {
        Group {
            if let m = marquee {
                let o = transform.toScreen(m.origin)
                Rectangle()
                    .fill(DraculaTheme.selection.color.opacity(0.08))
                    .overlay(Rectangle().stroke(DraculaTheme.selection.color.opacity(0.8), lineWidth: 1))
                    .frame(width: m.width * transform.zoom, height: m.height * transform.zoom)
                    .offset(x: o.x, y: o.y)
            }
        }
        .allowsHitTesting(false)
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

    // MARK: Node drag (whole selection, one transaction)

    private func beginNodeDrag() {
        canvasFocused = true
        dragOrigins = [:]
        for id in model.selection {
            if let p = model.document.root.nodes[id]?.position { dragOrigins[id] = p }
        }
        if model.isInTransaction { model.endTransaction() }   // defensive reset: an interrupted drag can leave one open
        model.beginTransaction("Move")
    }

    private func moveSelection(by t: CGSize) {
        guard !dragOrigins.isEmpty else { return }
        var moves: [NodeID: CGPoint] = [:]
        for (id, o) in dragOrigins { moves[id] = CGPoint(x: o.x + t.width, y: o.y + t.height) }
        model.apply(.moveNodes(moves))
    }

    private func endNodeDrag() {
        model.endTransaction()
        dragOrigins = [:]
    }

    // MARK: Background: marquee / pan / click

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                canvasFocused = true
                if spaceHeld {
                    if panOrigin == nil { panOrigin = transform.pan }
                    transform.pan = CGSize(width: panOrigin!.width + g.translation.width, height: panOrigin!.height + g.translation.height)
                    return
                }
                let p = transform.toCanvas(g.location)
                if marqueeStart == nil { marqueeStart = transform.toCanvas(g.startLocation) }
                let s = marqueeStart!
                marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            }
            .onEnded { g in
                defer { panOrigin = nil; marqueeStart = nil; marquee = nil }
                if panOrigin != nil { model.viewState.cameras[.root] = transform.camera; return }
                let moved = abs(g.translation.width) >= 4 || abs(g.translation.height) >= 4
                if moved, let m = marquee {
                    let hit = NodeGeometry.nodes(in: model.document.root, intersecting: m, registry: model.registry)
                    model.select(nodes: hit, mode: InputModifiers.shiftHeld ? .add : .replace)
                } else {
                    click(at: transform.toCanvas(g.location))
                }
            }
    }

    private func click(at p: CGPoint) {
        var best: (SocketRef, CGFloat)?
        for (to, from) in model.document.root.inputs {
            guard let a = anchors[from], let b = anchors[to] else { continue }
            let d = WireGeometry.distance(from: p, wireFrom: a, to: b)
            if d <= Self.wireHitDistance / transform.zoom && (best == nil || d < best!.1) { best = (to, d) }
        }
        if let (wire, _) = best {
            model.selection = []
            model.selectedWire = wire
        } else {
            model.clearSelection()
        }
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
