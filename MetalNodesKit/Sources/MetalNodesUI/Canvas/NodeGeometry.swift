import CoreGraphics
import MetalNodesCore

/// Node frames without measuring views: a fixed width and an estimated height from the
/// row count. Used for marquee hits, culling, zoom-to-fit and paste placement (spec §18.9).
enum NodeGeometry {
    static let width: CGFloat = 190
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 22
    static let bodyPadding: CGFloat = 16

    static func estimatedSize(for def: NodeDef) -> CGSize {
        let rows = def.inputs.count + def.params.count + def.outputs.count
        return CGSize(width: width, height: headerHeight + bodyPadding + CGFloat(rows) * rowHeight)
    }

    static func frame(for node: NodeInstance, def: NodeDef) -> CGRect {
        CGRect(origin: node.position, size: estimatedSize(for: def))
    }

    static func frame(for node: NodeInstance, registry: NodeRegistry) -> CGRect? {
        guard case .builtin(let id) = node.kind, let def = registry[id] else { return nil }
        return frame(for: node, def: def)
    }

    static func nodes(in graph: Graph, intersecting rect: CGRect, registry: NodeRegistry) -> Set<NodeID> {
        var out = Set<NodeID>()
        for n in graph.nodes.values {
            if let f = frame(for: n, registry: registry), f.intersects(rect) { out.insert(n.id) }
        }
        return out
    }

    static func bounds(of ids: some Collection<NodeID>, in graph: Graph, registry: NodeRegistry) -> CGRect? {
        var acc: CGRect?
        for id in ids {
            guard let n = graph.nodes[id], let f = frame(for: n, registry: registry) else { continue }
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
    static func visibleNodes(in graph: Graph, transform: CanvasTransform, viewport: CGSize,
                             registry: NodeRegistry, margin: CGFloat = 200,
                             keeping: Set<NodeID> = []) -> [NodeInstance] {
        let rect = transform.visibleRect(viewport: viewport).insetBy(dx: -margin, dy: -margin)
        return graph.nodes.values
            .filter { n in keeping.contains(n.id) || frame(for: n, registry: registry)?.intersects(rect) == true }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
    }
}
