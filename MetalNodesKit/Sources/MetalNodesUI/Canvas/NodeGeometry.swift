import CoreGraphics
import MetalNodesCore

/// Node frames without measuring views: a fixed width and an estimated height from the
/// row count. Used for marquee hits, culling, zoom-to-fit and paste placement (spec §18.9).
///
/// Everything works off a node's `NodeShape` (spec §20.2), so a group instance and a pseudo-node
/// lay out exactly like a builtin, from their exposed sockets. Callers pass a `shapes` closure —
/// in the app `EditorModel.shape(of:)`, which knows the active graph's path.
enum NodeGeometry {
    /// A node's width with the narrowest label column. Canvas placement (`GraphCanvasView`)
    /// centres new nodes on this; a node's real width is `width(for:)`.
    static let baseWidth: CGFloat = 190
    static var width: CGFloat { baseWidth }
    /// The label column every one-line body row shares: `ParamControl`'s `frame(width:)`.
    static let minLabelColumn: CGFloat = 46
    /// Wide enough for "Clearcoat Roughness" at `.caption` size; nothing in the library is longer.
    static let maxLabelColumn: CGFloat = 120
    /// An estimate of `.caption`'s average advance, rounded up so it errs wide: a label that
    /// wraps is the defect (handoff §15.3.1), a column a few points too wide is not.
    static let captionPointsPerCharacter: CGFloat = 6.4
    static let headerHeight: CGFloat = 26
    /// Row pitch: `NodeView`'s 16 pt of row content plus the body `VStack`'s 6 pt spacing.
    static let rowHeight: CGFloat = 22
    static let rowSpacing: CGFloat = 6
    /// `NodeView`'s body inset, top and bottom.
    static let bodyPadding: CGFloat = 16
    /// A `.dot` node (Reroute) is square and has no header or body (spec §19.5).
    static let dotSize: CGFloat = 24

    /// Rows a shape's body params take: params with `showsInBody == false` live in the
    /// inspector only, so they take no vertical space here (spec §19.5). A multiline `.text`
    /// param (Task 17's code editor reusing `ParamControl`) needs 3; every other param, single-line
    /// `.text` included, takes the one row every other control does.
    ///
    /// Shared by `bodyRows` and `socketAnchor`'s output-row offset — both must agree on how many
    /// rows a body's params occupy, or a node's estimated height and its socket dots' computed
    /// positions disagree (Task 15 fix round 1).
    static func paramRows(_ shape: NodeShape) -> Int {
        shape.params.filter(\.showsInBody).reduce(0) { total, p in
            if case .text(let multiline) = p.kind, multiline { return total + 3 }
            return total + 1
        }
    }

    /// Rows `NodeView` actually lays out: inputs, then body params, then outputs.
    static func bodyRows(_ shape: NodeShape) -> Int {
        shape.inputs.count + paramRows(shape) + shape.outputs.count
    }

    /// The label column for `shape`'s body rows — inputs and body params, the two row kinds that
    /// draw a leading label — from its longest label. One function, two readers: `NodeView`
    /// passes it to every `ParamControl`, and `estimatedSize` widens the node by the same amount,
    /// so the estimate and the drawing cannot disagree (spec §25.2, handoff §15.5 item 8). An
    /// `.enumeration` param draws its label inside the picker control, not the column, and a
    /// multiline `.text` param draws its label above the editor rather than beside it, so neither
    /// contributes to the column's width (final review, M9).
    static func labelColumnWidth(for shape: NodeShape) -> CGFloat {
        let labels = shape.inputs.map(\.label) + shape.params.filter { p in
            guard p.showsInBody else { return false }
            switch p.kind {
            case .enumeration: return false
            case .text(let multiline): return !multiline
            default: return true
            }
        }.map(\.label)
        let longest = labels.map(\.count).max() ?? 0
        return min(maxLabelColumn, max(minLabelColumn, (CGFloat(longest) * captionPointsPerCharacter).rounded(.up)))
    }

    static func width(for shape: NodeShape) -> CGFloat {
        shape.style == .dot ? dotSize : baseWidth + labelColumnWidth(for: shape) - minLabelColumn
    }

    static func estimatedSize(for shape: NodeShape) -> CGSize {
        if shape.style == .dot { return CGSize(width: dotSize, height: dotSize) }
        return CGSize(width: width(for: shape), height: headerHeight + bodyPadding + CGFloat(bodyRows(shape)) * rowHeight)
    }

    static func frame(for node: NodeInstance, shape: NodeShape) -> CGRect {
        CGRect(origin: node.position, size: estimatedSize(for: shape))
    }

    static func frame(for node: NodeInstance, shapes: (NodeInstance) -> NodeShape?) -> CGRect? {
        shapes(node).map { frame(for: node, shape: $0) }
    }

    /// Where `NodeView` puts `ref`'s socket dot, in canvas coordinates, computed rather than
    /// measured. `SocketAnchorKey` only reports sockets that are actually rendered, so a culled
    /// node (or one below the LOD zoom) has no measured anchor; this is the fallback that keeps
    /// its wires drawn and hit-testable (spec §18.9, "wires always draw").
    ///
    /// Mirrors `NodeView`'s expanded layout exactly: below the header and the 8 pt body inset it
    /// stacks one `rowHeight` row per input, then per param, then per output, each row's
    /// `rowHeight - rowSpacing` of content centred in its pitch. `NodeView.inputRow` offsets its
    /// socket by `-8 - SocketView.size / 2`, exactly cancelling the inset and half the dot, so
    /// the dot's centre sits on the node's left edge; `outputRow` mirrors it onto the right edge.
    ///
    /// A `.dot` node has no rows: its single input sits on the left edge's centre and its single
    /// output on the right edge's, matching `NodeView.dotBody`.
    static func socketAnchor(for ref: SocketRef, in graph: Graph, shapes: (NodeInstance) -> NodeShape?) -> CGPoint? {
        guard let node = graph.nodes[ref.node], let shape = shapes(node) else { return nil }
        if shape.style == .dot {
            if shape.input(named: ref.socket) != nil {
                return CGPoint(x: node.position.x, y: node.position.y + dotSize / 2)
            }
            if shape.output(named: ref.socket) != nil {
                return CGPoint(x: node.position.x + dotSize, y: node.position.y + dotSize / 2)
            }
            return nil
        }
        func centreY(row: Int) -> CGFloat {
            node.position.y + headerHeight + bodyPadding / 2 + CGFloat(row) * rowHeight + (rowHeight - rowSpacing) / 2
        }
        if let i = shape.inputs.firstIndex(where: { $0.name == ref.socket }) {
            return CGPoint(x: node.position.x, y: centreY(row: i))
        }
        if let i = shape.outputs.firstIndex(where: { $0.name == ref.socket }) {
            let above = shape.inputs.count + paramRows(shape)
            return CGPoint(x: node.position.x + width(for: shape), y: centreY(row: above + i))
        }
        return nil
    }

    static func nodes(in graph: Graph, intersecting rect: CGRect, shapes: (NodeInstance) -> NodeShape?) -> Set<NodeID> {
        var out = Set<NodeID>()
        for n in graph.nodes.values {
            if let f = frame(for: n, shapes: shapes), f.intersects(rect) { out.insert(n.id) }
        }
        return out
    }

    static func bounds(of ids: some Collection<NodeID>, in graph: Graph, shapes: (NodeInstance) -> NodeShape?) -> CGRect? {
        var acc: CGRect?
        for id in ids {
            guard let n = graph.nodes[id], let f = frame(for: n, shapes: shapes) else { continue }
            acc = acc.map { $0.union(f) } ?? f
        }
        return acc
    }

    /// Nodes whose frame intersects the viewport (in canvas units) grown by `margin`, in stable UUID order.
    ///
    /// `keeping` survives culling regardless: a node whose `NodeView` owns a live gesture (a header
    /// drag, a socket drag) must not be torn down mid-gesture, or SwiftUI cancels the gesture without
    /// ever calling `onEnded` and the drag's undo transaction stays open. Kept ids join the same
    /// UUID order rather than being appended, so z-order does not shift when a node leaves the
    /// viewport.
    ///
    /// `onTop` (the selection) draws last — the canvas renders this array in order, so the
    /// selected nodes end up above the rest. `EditorModel.node(at:)` sorts the same way, keeping
    /// hit-testing and draw order in agreement (spec §19.6).
    static func visibleNodes(in graph: Graph, transform: CanvasTransform, viewport: CGSize,
                             shapes: (NodeInstance) -> NodeShape?, margin: CGFloat = 200,
                             keeping: Set<NodeID> = [], onTop: Set<NodeID> = []) -> [NodeInstance] {
        let rect = transform.visibleRect(viewport: viewport).insetBy(dx: -margin, dy: -margin)
        return graph.nodes.values
            .filter { n in keeping.contains(n.id) || frame(for: n, shapes: shapes)?.intersects(rect) == true }
            .sorted { drawOrder($0, onTop: onTop) < drawOrder($1, onTop: onTop) }
    }

    /// The canvas's z-order key: `onTop` nodes last, then stable UUID order.
    static func drawOrder(_ node: NodeInstance, onTop: Set<NodeID>) -> (Int, String) {
        (onTop.contains(node.id) ? 1 : 0, node.id.raw.uuidString)
    }
}
