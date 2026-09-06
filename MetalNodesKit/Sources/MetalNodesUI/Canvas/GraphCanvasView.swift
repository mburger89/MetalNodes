import SwiftUI
import MetalNodesCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// A wire being dragged: from `source` (always an output socket) to the cursor.
struct PendingWire: Equatable {
    var source: SocketRef
    var type: SocketType
    var point: CGPoint
    /// A drag from a `GroupInput`'s `+`: the socket it will create has no type yet, so nothing
    /// dims and any non-texture input takes it (spec §20.6).
    var isWildcard = false
}

/// What a drag that started on the background is doing. Decided on the first change and then
/// latched for the rest of the drag — see `GraphCanvasView.backgroundDrag`.
enum BackgroundDragMode { case pan, wire, marquee }

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
    /// ⌥-drag: duplication is deferred until the drag actually moves (see `beginNodeDrag`),
    /// so a zero-movement ⌥-click doesn't leave invisible copies stacked on the originals.
    @State private var pendingDuplicate = false
    @State private var pendingWire: PendingWire?
    /// The comment move or resize in flight, and what it started from (spec §21.4).
    @State private var commentDrag: CommentDrag?
    /// Latched for the duration of one background drag, so releasing or pressing space midway
    /// cannot switch a live wire drag or marquee into a pan (and strand its transaction).
    @State private var dragMode: BackgroundDragMode?
    @State private var viewport: CGSize = .zero
    @FocusState private var canvasFocused: Bool
    /// Why the chooser is open: where to place, and (for a wire drop) what to auto-wire.
    struct Chooser: Identifiable {
        let id = UUID()
        var canvasPoint: CGPoint
        var screenPoint: CGPoint
        var wire: (source: SocketRef, type: SocketType)?
    }
    @State private var chooser: Chooser?
    @State private var hoverLocation: CGPoint = .zero      // viewport coords, for ⇧A
    /// Last background click (viewport coords), for synthesising double-click since
    /// `backgroundDrag` already claims single clicks — see its `onEnded` click branch.
    @State private var lastClick: (time: Date, point: CGPoint)?

    static let contentSize: CGFloat = 4000
    static let wireHitDistance: CGFloat = 6
    static let lodZoom: CGFloat = 0.4
    static let cullMargin: CGFloat = 200

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
                #if os(macOS)
                ScrollWheelCatcher { delta, location, cmd, precise in
                    if cmd {
                        transform.zoom(by: zoomFactor(for: delta, precise: precise), around: location)
                    } else {
                        transform.pan(by: delta)
                    }
                    model.viewState.cameras[model.activePath] = transform.camera
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                #endif
            }
            .onAppear { viewport = geo.size; hoverLocation = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2) }
            .onChange(of: geo.size) { _, s in viewport = s }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if model.viewState.showsMinimap, viewport != .zero {
                    MinimapView(model: model, viewportRect: transform.visibleRect(viewport: viewport))
                        .padding(12)
                }
            }
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
            .onKeyPress(.escape) {
                // Cancel, not commit: a re-drag has already applied its `.disconnect`, and Escape
                // must put that wire back rather than register it as an undo step (spec §18.5).
                if pendingWire != nil { pendingWire = nil; model.cancelTransaction() } else { model.clearSelection() }
                return .handled
            }
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
                model.canvasHasFocus = focused
                if !focused { spaceHeld = false }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverLocation = p
                case .ended: hoverLocation = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
                }
            }
            .onKeyPress(characters: .init(charactersIn: "aA")) { press in
                guard press.modifiers == .shift else { return .ignored }
                openChooser(atScreen: hoverLocation, wire: nil)
                return .handled
            }
            .dropDestination(for: NodeDefTransfer.self) { items, location in
                guard let t = items.first else { return false }
                let c = transform.toCanvas(location)
                let origin = CGPoint(x: c.x - NodeGeometry.width / 2, y: c.y - NodeGeometry.headerHeight / 2)
                // A "My Functions" row: `addInstance` refuses (with a notice) a drop that would
                // make a definition contain itself, spec §20.8.
                if let g = t.groupID { return model.addInstance(of: g, at: origin) != nil }
                guard let defID = t.defID else { return false }
                return model.addNode(defID: defID, at: origin) != nil
            }
            // An image file from the Finder becomes a Texture Sample already pointing at it
            // (spec §21.2). `addTextureNode` explains every refusal it makes — a link rather than a
            // file, an unreadable file, bytes no decoder knows — with a notice. Only the first URL
            // of a multi-file drop is placed; a node per file is not what the spec asks for.
            .dropDestination(for: URL.self) { urls, location in
                guard let url = urls.first else { return false }
                let c = transform.toCanvas(location)
                let origin = CGPoint(x: c.x - NodeGeometry.width / 2, y: c.y - NodeGeometry.headerHeight / 2)
                return model.addTextureNode(contentsOf: url, at: origin) != nil
            }
            // The binding's setter is also how the popover reports a dismissal we did not ask for
            // (a click outside), so `dismissChooser` — not just `onCancel` — is what abandons a
            // wire drop's still-open transaction.
            .popover(item: Binding(get: { chooser }, set: { if $0 == nil { dismissChooser() } else { chooser = $0 } }),
                     attachmentAnchor: .rect(.rect(CGRect(origin: chooser?.screenPoint ?? .zero, size: CGSize(width: 1, height: 1)))), arrowEdge: .top) { c in
                NodeSearchPopover(rows: { query in
                    var rows = PaletteSearch.rows(query: query, registry: model.registry, document: model.document)
                    // A wire-drop chooser only lists rows the wire could actually connect to —
                    // builtins and "My Functions" definitions alike (spec §21.7).
                    if let w = c.wire {
                        rows = rows.filter { row in
                            switch row {
                            case .builtin(let d): PaletteSearch.acceptsInput(of: w.type, d)
                            case .definition(let d): PaletteSearch.acceptsInput(of: w.type, d)
                            }
                        }
                    }
                    return rows
                }, onPick: { row in
                    switch row {
                    case .builtin(let def): place(def, for: c)
                    case .definition(let def): placeDefinition(def, for: c)
                    }
                }, onCancel: { dismissChooser() })
            }
            #if os(macOS)
            // Responder-chain commands (rather than menu key equivalents) so a focused node
            // parameter `TextField` gets first crack at Delete/Select All — see EditorCommands.
            .onDeleteCommand { model.deleteSelection() }
            .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
            // Not onCut/onCopyCommand: those clear the pasteboard and write the handler's item
            // providers afterwards, which wipes a direct write — and a promised custom UTI never
            // resolves to bytes. Handling the responder selectors keeps our own write in place.
            .onCommand(#selector(NSText.cut(_:))) { model.cutSelection() }
            .onCommand(#selector(NSText.copy(_:))) { model.copySelection() }
            // At the pointer (spec §18.4). `hoverLocation` is the last position inside the viewport
            // and falls back to its centre once the pointer leaves, so a menu paste lands centred.
            .onPasteCommand(of: [.metalNodesGraph]) { _ in model.paste(at: transform.toCanvas(hoverLocation)) }
            #endif
        }
        .onPreferenceChange(SocketAnchorKey.self) { anchors = $0 }
        .onAppear { if let cam = model.viewState.cameras[model.activePath] { transform = CanvasTransform(camera: cam) } }
        .onAppear { canvasFocused = true; model.canvasHasFocus = true }
        // One camera per graph (spec §20.3): diving in or out parks the camera on the graph being
        // left and restores the one the graph being entered was last seen at, unpanned if it is new.
        .onChange(of: model.activePath) { old, new in
            model.viewState.cameras[old] = transform.camera
            transform = model.viewState.cameras[new].map { CanvasTransform(camera: $0) } ?? CanvasTransform()
        }
        .onChange(of: model.canvasRequest) { _, req in
            guard let req else { return }
            defer { model.canvasRequest = nil }
            let rect: CGRect?
            switch req {
            case .place(let defID):
                model.addNode(defID: defID, at: placementPoint)
                return
            case .placeGroup(let id):
                model.addInstance(of: id, at: placementPoint)
                return
            case .centerOn(let point):
                guard viewport != .zero else { return }
                transform.pan = CGSize(width: viewport.width / 2 - point.x * transform.zoom,
                                       height: viewport.height / 2 - point.y * transform.zoom)
                model.viewState.cameras[model.activePath] = transform.camera
            case .addSticky:
                // ⌘⇧N centres the note on the viewport, not its top-left corner (spec §21.4).
                model.addSticky(centredAt: transform.toCanvas(CGPoint(x: viewport.width / 2, y: viewport.height / 2)))
                return
            case .fitAll: rect = model.contentBounds
            case .fitSelection: rect = model.selectionBounds ?? model.contentBounds
            }
            guard let r = rect, viewport != .zero else { return }
            transform = CanvasTransform.fitting(r, in: viewport, padding: 40)
            model.viewState.cameras[model.activePath] = transform.camera
        }
    }

    /// Where a palette double-click drops a node: the viewport's centre, offset so the node's
    /// header — not its top-left corner — lands there.
    private var placementPoint: CGPoint {
        let centre = transform.toCanvas(CGPoint(x: viewport.width / 2, y: viewport.height / 2))
        return CGPoint(x: centre.x - NodeGeometry.width / 2, y: centre.y - NodeGeometry.headerHeight / 2)
    }

    // MARK: Content

    /// Every node's `NodeShape` in the active graph — builtin, group instance or pseudo-node —
    /// which is what geometry, wiring and `NodeView` all lay out from (spec §20.2).
    private var shapes: (NodeInstance) -> NodeShape? { { model.shape(of: $0) } }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            // Comments sit above the grid and below the wires and the nodes (spec §21.4).
            CommentLayer(graph: model.graph, selected: model.selectedComments,
                         visible: cullRect, keeping: commentsInFlight,
                         onSelect: { id, mode in canvasFocused = true; model.selectComment(id, mode: mode) },
                         onDragBegan: { id, resizing in beginCommentDrag(id, resizing: resizing) },
                         onDrag: { dragComments(by: $0) },
                         onDragEnded: { endCommentDrag() })
            WireLayer(graph: model.graph, anchors: anchors, shapes: shapes,
                      selected: model.selectedWire, pending: pendingWire) { from in
                if let t = model.resolvedTypes[from.node]?.outputTypes[from.socket] {
                    return DraculaTheme.token(for: t).color
                }
                return DraculaTheme.wireDefault.color
            }
            let compact = transform.zoom < Self.lodZoom
            let errors = model.errorNodes
            // The selection draws last, so a node dragged over its neighbours stays on top —
            // `EditorModel.node(at:)` orders hit-testing to match (spec §19.6).
            let onTop = model.selection
            let visible = viewport == .zero
                ? model.graph.nodes.values
                    .sorted { NodeGeometry.drawOrder($0, onTop: onTop) < NodeGeometry.drawOrder($1, onTop: onTop) }
                : NodeGeometry.visibleNodes(in: model.graph, transform: transform, viewport: viewport,
                                            shapes: shapes, margin: Self.cullMargin,
                                            keeping: nodesInFlight, onTop: onTop)
            ForEach(visible, id: \.id) { node in
                if let shape = model.shape(of: node) {
                    NodeView(node: node, shape: shape, resolved: model.resolvedTypes[node.id],
                             graph: model.graph,
                             isSelected: model.selection.contains(node.id),
                             compact: compact,
                             isViewed: model.viewer?.node == node.id,
                             hasError: errors.contains(node.id),
                             onViewerToggle: { if let ref = model.firstOutput(of: node.id) { model.toggleViewer(ref) } },
                             onOpen: { model.diveIn(node.id) },
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
                             },
                             // A wildcard drag has no type to judge sockets against, so it dims
                             // nothing (spec §20.6).
                             dragType: pendingWire.flatMap { $0.isWildcard ? nil : $0.type },
                             onSocketDragBegan: { ref, isInput in beginWire(from: ref, isInput: isInput) },
                             onSocketDrag: { p in pendingWire?.point = p },
                             onSocketDragEnded: { p in endWire(at: p) })
                        .offset(x: node.position.x, y: node.position.y)
                }
            }
        }
        .coordinateSpace(.named("canvas"))
    }

    /// Nodes whose `NodeView` is running a gesture right now: the dragged selection and, for a
    /// socket drag, the wire's source node. Culling must not remove them (see `visibleNodes`).
    private var nodesInFlight: Set<NodeID> {
        var ids = Set(dragOrigins.keys)
        if let w = pendingWire { ids.insert(w.source.node) }
        return ids
    }

    /// Comments whose view is running a drag right now — the same protection `nodesInFlight` gives.
    private var commentsInFlight: Set<CommentID> { commentDrag.map { Set($0.rects.keys) } ?? [] }

    /// What `CommentLayer` culls against: the viewport grown by the margin, or nil before the
    /// viewport is known (in which case everything draws, as it does for nodes).
    private var cullRect: CGRect? {
        viewport == .zero ? nil : transform.visibleRect(viewport: viewport).insetBy(dx: -Self.cullMargin, dy: -Self.cullMargin)
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
        if model.isInTransaction { model.endTransaction() }   // defensive reset: an interrupted drag can leave one open
        pendingDuplicate = InputModifiers.optionHeld && !model.selection.isEmpty
        model.beginTransaction(pendingDuplicate ? "Duplicate" : "Move")
        dragOrigins = [:]
        for id in model.selection {
            if let p = model.graph.nodes[id]?.position { dragOrigins[id] = p }
        }
    }

    private func moveSelection(by t: CGSize) {
        if pendingDuplicate, abs(t.width) >= 1 || abs(t.height) >= 1 {
            pendingDuplicate = false
            model.duplicateSelection(offset: .zero)   // selection is now the copies, in place
            dragOrigins = [:]
            for id in model.selection {
                if let p = model.graph.nodes[id]?.position { dragOrigins[id] = p }
            }
        }
        guard !dragOrigins.isEmpty else { return }
        var moves: [NodeID: CGPoint] = [:]
        for (id, o) in dragOrigins { moves[id] = CGPoint(x: o.x + t.width, y: o.y + t.height) }
        model.apply(.moveNodes(moves))
    }

    private func endNodeDrag() {
        model.endTransaction()
        dragOrigins = [:]
        pendingDuplicate = false
    }

    // MARK: Comment drag (spec §21.4)

    /// A comment drag in flight: the rects it started from — and, for a frame move, the positions
    /// of the nodes it owned when the drag began, since membership is geometry read once (§11.5).
    struct CommentDrag {
        /// Set when the corner handle started this, in which case `rects` holds only that comment.
        var resizing: CommentID?
        var rects: [CommentID: CGRect] = [:]
        var nodes: [NodeID: CGPoint] = [:]
    }

    private func beginCommentDrag(_ id: CommentID, resizing: Bool) {
        canvasFocused = true
        if model.isInTransaction { model.endTransaction() }   // defensive reset, as node drags do
        if resizing {
            guard let rect = model.graph[comment: id] else { return }
            model.beginTransaction("Resize")
            commentDrag = CommentDrag(resizing: id, rects: [id: rect])
            return
        }
        // The whole comment selection moves together, exactly as the node selection does.
        var rects: [CommentID: CGRect] = [:]
        for c in model.selectedComments.union([id]) {
            if let r = model.graph[comment: c] { rects[c] = r }
        }
        var nodes: [NodeID: CGPoint] = [:]
        var movesAFrame = false
        for case .frame(let f) in rects.keys {
            movesAFrame = true
            for n in model.members(of: f) {
                if let p = model.graph.nodes[n]?.position { nodes[n] = p }
            }
        }
        model.beginTransaction(movesAFrame ? "Move Frame" : "Move")
        commentDrag = CommentDrag(rects: rects, nodes: nodes)
    }

    private func dragComments(by t: CGSize) {
        guard let d = commentDrag else { return }
        if let id = d.resizing {
            guard let r = d.rects[id] else { return }
            model.apply(.resizeComment(id, EditorModel.resized(r, by: t)))
            return
        }
        var moves: [CommentID: CGPoint] = [:]
        for (id, r) in d.rects { moves[id] = CGPoint(x: r.minX + t.width, y: r.minY + t.height) }
        model.apply(.moveComments(moves))
        if !d.nodes.isEmpty {
            var members: [NodeID: CGPoint] = [:]
            for (id, p) in d.nodes { members[id] = CGPoint(x: p.x + t.width, y: p.y + t.height) }
            model.apply(.moveNodes(members))
        }
    }

    private func endCommentDrag() {
        model.endTransaction()
        commentDrag = nil
    }

    // MARK: Wiring (spec §18.5)

    private func beginWire(from ref: SocketRef, isInput: Bool) {
        canvasFocused = true
        let g = model.graph
        if isInput {
            // Re-drag: detach the existing wire and continue from its source, as one undo step.
            guard let source = g.source(feeding: ref) else { return }
            guard let t = DropResolver.outputType(of: source, graph: model.graph, shapes: shapes, resolved: model.resolvedTypes) else { return }
            if model.isInTransaction { model.endTransaction() }   // defensive reset
            model.beginTransaction("Rewire")
            model.apply(.disconnect(ref))
            pendingWire = PendingWire(source: source, type: t, point: anchors[ref] ?? .zero)
        } else {
            guard let t = DropResolver.outputType(of: ref, graph: g, shapes: shapes, resolved: model.resolvedTypes) else { return }
            if model.isInTransaction { model.endTransaction() }   // defensive reset
            model.beginTransaction("Connect")
            pendingWire = PendingWire(source: ref, type: t, point: anchors[ref] ?? .zero,
                                      isWildcard: DropResolver.isPlusOutput(ref, in: g))
        }
    }

    /// The definition the active graph belongs to — what exposing a socket adds to (spec §20.3).
    private var activeDefinition: GroupID? {
        if case .definition(let g) = model.activePath { return g }
        return nil
    }

    private func endWire(at p: CGPoint) {
        guard let w = pendingWire else { return }
        pendingWire = nil
        let target = DropResolver.resolve(point: p, source: w.source, dragType: w.type, wildcard: w.isWildcard,
                                          anchors: anchors, graph: model.graph, shapes: shapes, resolved: model.resolvedTypes)
        if let gid = activeDefinition, exposeSocket(for: w, at: target, in: gid) { return }
        switch target {
        case .socket(let input):
            model.connectIfCompatible(w.source, to: input)
            model.endTransaction()
        case .node(let id):
            if let input = DropResolver.firstCompatibleInput(on: id, for: w.type, graph: model.graph,
                                                             shapes: shapes, resolved: model.resolvedTypes) {
                model.connectIfCompatible(w.source, to: input)
            }
            model.endTransaction()
        case .empty:
            // The drag's transaction stays open across the chooser: picking commits the node and
            // the connection into that one step, dismissing abandons it — which is what rolls a
            // re-drag's `.disconnect` back (see `place` and `dismissChooser`).
            openChooser(atScreen: transform.toScreen(p), wire: (w.source, w.type))
        }
    }

    /// The `+` drops (spec §20.6): onto a `GroupOutput`'s `+` exposes an output, and a wildcard
    /// drag from a `GroupInput`'s `+` exposes an input wherever it lands — with no chooser on empty
    /// canvas, since there is nothing to name a socket after. True when this handled the drop.
    ///
    /// The drag's own transaction closes first, so the expose is a single undo step of its own,
    /// named for what it did. A plain drag has changed nothing by then and registers nothing; only
    /// a re-drag — whose `.disconnect` is already applied — leaves that detachment as a step before it.
    private func exposeSocket(for w: PendingWire, at target: DropTarget, in gid: GroupID) -> Bool {
        switch target {
        case .socket(let input) where DropResolver.isPlusInput(input, in: model.graph):
            model.endTransaction()
            model.exposeOutput(from: w.source, in: gid)
        case .socket(let input) where w.isWildcard:
            model.endTransaction()
            model.exposeInput(to: input, in: gid)
        case .node(let id) where w.isWildcard:
            model.endTransaction()
            if let input = DropResolver.firstCompatibleInput(on: id, for: w.type, wildcard: true, graph: model.graph,
                                                             shapes: shapes, resolved: model.resolvedTypes) {
                model.exposeInput(to: input, in: gid)
            }
        case .empty where w.isWildcard:
            model.cancelTransaction()               // a wildcard dropped on nothing is abandoned, not committed
        default:
            return false
        }
        return true
    }

    // MARK: Chooser popover (⇧A / double-click / wire-drop-on-empty)

    private func openChooser(atScreen p: CGPoint, wire: (SocketRef, SocketType)?) {
        chooser = Chooser(canvasPoint: transform.toCanvas(p), screenPoint: p, wire: wire.map { (source: $0.0, type: $0.1) })
    }

    private func place(_ def: NodeDef, for c: Chooser) {
        placeAndWire(for: c) { model.addNode(defID: def.id, at: $0) }
    }

    /// A "My Functions" pick (spec §21.7): `addInstance` can refuse (a definition cannot contain
    /// itself) — it shows the notice and returns `nil` itself, so `placeAndWire` simply has
    /// nothing to wire; the open transaction still closes cleanly with no document change.
    private func placeDefinition(_ def: GroupDefinition, for c: Chooser) {
        placeAndWire(for: c) { model.addInstance(of: def.id, at: $0) }
    }

    /// Shared by `place` and `placeDefinition`: commits `place` at `c`'s canvas point (joining a
    /// wire drop's open transaction) and, when it placed a node and `c` came from a wire drop,
    /// wires the pending wire to the new node's first compatible input.
    private func placeAndWire(for c: Chooser, place: (CGPoint) -> NodeID?) {
        chooser = nil                                   // not through `dismissChooser`: this commits
        model.beginTransaction("Add Node")              // joins a wire drop's open transaction
        let origin = CGPoint(x: c.canvasPoint.x - NodeGeometry.width / 2, y: c.canvasPoint.y - NodeGeometry.headerHeight / 2)
        if let id = place(origin), let w = c.wire,
           let input = DropResolver.firstCompatibleInput(on: id, for: w.type, graph: model.graph,
                                                         shapes: shapes, resolved: model.resolvedTypes) {
            model.connectIfCompatible(w.source, to: input)
        }
        model.endTransaction()
        if c.wire != nil { model.endTransaction() }      // and closes it, as one undo step
    }

    /// Closes the chooser without placing anything. A chooser opened by a wire drop still owns
    /// that drag's transaction, so dismissing it cancels: a re-drag's `.disconnect` is rolled
    /// back instead of being registered as an undo step (spec §18.5).
    private func dismissChooser() {
        if chooser?.wire != nil { model.cancelTransaction() }
        chooser = nil
    }

    // MARK: Background: marquee / pan / click

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                canvasFocused = true
                let mode = dragMode ?? beginBackgroundDrag(g)
                dragMode = mode
                switch mode {
                case .pan:
                    let o = panOrigin ?? transform.pan
                    transform.pan = CGSize(width: o.width + g.translation.width, height: o.height + g.translation.height)
                case .wire:
                    pendingWire?.point = transform.toCanvas(g.location)
                case .marquee:
                    let p = transform.toCanvas(g.location), s = marqueeStart ?? p
                    marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                }
            }
            .onEnded { g in
                defer { dragMode = nil; panOrigin = nil; marqueeStart = nil; marquee = nil }
                switch dragMode {
                case .pan:
                    model.viewState.cameras[model.activePath] = transform.camera
                case .wire:
                    // Ends the wire whatever the space key is doing now — a latched wire drag
                    // must always reach `endWire`, which closes its transaction.
                    endWire(at: transform.toCanvas(g.location))
                case .marquee, nil:                       // nil: pressed and released without a change
                    let moved = abs(g.translation.width) >= 4 || abs(g.translation.height) >= 4
                    if moved, let m = marquee {
                        // Nodes and comments in one pass, so neither clears the other (spec §21.4).
                        let hit = NodeGeometry.nodes(in: model.graph, intersecting: m, shapes: shapes)
                        model.select(nodes: hit, comments: model.comments(intersecting: m),
                                     mode: InputModifiers.shiftHeld ? .add : .replace)
                    } else if let last = lastClick, Date.now.timeIntervalSince(last.time) < 0.4,
                              hypot(g.location.x - last.point.x, g.location.y - last.point.y) <= 4 {
                        lastClick = nil
                        openChooser(atScreen: g.location, wire: nil)
                    } else {
                        click(at: transform.toCanvas(g.location))
                        lastClick = (time: .now, point: g.location)
                    }
                }
            }
    }

    /// Chooses what this background drag is, once, from the state at the press: space held → pan;
    /// a socket under the press that actually starts a wire → wire; otherwise marquee.
    private func beginBackgroundDrag(_ g: DragGesture.Value) -> BackgroundDragMode {
        if spaceHeld {
            panOrigin = transform.pan
            return .pan
        }
        if let hit = socketUnderPress(atScreen: g.startLocation) {
            beginWire(from: hit.ref, isInput: hit.isInput)
            if pendingWire != nil { return .wire }
        }
        marqueeStart = transform.toCanvas(g.startLocation)
        return .marquee
    }

    /// Sockets are centred on their node's edge, and hit-testing stops at the node's frame, so a
    /// press on a socket's outboard half reaches the background gesture instead of `SocketView`'s
    /// drag. Resolve it against the socket anchors so the wire still starts. Not in compact LOD
    /// (no socket drags there, by design).
    private func socketUnderPress(atScreen p: CGPoint) -> (ref: SocketRef, isInput: Bool)? {
        guard transform.zoom >= Self.lodZoom,
              let ref = DropResolver.socket(near: transform.toCanvas(p), within: SocketView.hitSize / 2 / transform.zoom, anchors: anchors),
              let node = model.graph.nodes[ref.node], let shape = model.shape(of: node) else { return nil }
        return (ref, shape.input(named: ref.socket) != nil)
    }

    /// The socket's measured anchor, or the computed one when it was not rendered (culled node) —
    /// the same fallback `WireLayer` draws with, so every drawn wire is also clickable.
    private func anchor(_ ref: SocketRef) -> CGPoint? {
        anchors[ref] ?? NodeGeometry.socketAnchor(for: ref, in: model.graph, shapes: shapes)
    }

    private func click(at p: CGPoint) {
        var best: (SocketRef, CGFloat)?
        for (to, from) in model.graph.inputs {
            guard let a = anchor(from), let b = anchor(to) else { continue }
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

    private func zoomFactor(for delta: CGSize, precise: Bool) -> CGFloat {
        exp(delta.height * (precise ? 0.01 : 0.1))
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if zoomOrigin == nil { zoomOrigin = transform.zoom }
                let target = zoomOrigin! * g.magnification
                transform.zoom(by: target / transform.zoom, around: g.startLocation)
            }
            .onEnded { _ in zoomOrigin = nil; model.viewState.cameras[model.activePath] = transform.camera }
    }
}
