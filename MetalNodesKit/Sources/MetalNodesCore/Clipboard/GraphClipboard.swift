import Foundation
import CoreGraphics

/// The pasteboard payload (spec §6, §18.4): a subgraph with positions relative to its own
/// bounding box, plus the definitions/comments it depends on (empty until M4/M5).
public struct GraphClipboard: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = GraphClipboard.currentFormatVersion
    /// Where the nodes came from (bounding-box origin), so a menu paste can offset from it.
    public var sourceOrigin: CGPoint
    public var nodes: [NodeInstance]
    public var edges: [Edge]
    public var stickies: [StickyNote] = []
    public var frames: [CommentFrame] = []
    public var definitions: [GroupDefinition] = []

    public init(nodes: [NodeInstance], edges: [Edge], sourceOrigin: CGPoint = .zero) {
        self.nodes = nodes
        self.edges = edges
        self.sourceOrigin = sourceOrigin
    }

    /// Extent of the relative node positions (top-left of each node; excludes node size).
    public var size: CGSize {
        guard !nodes.isEmpty else { return .zero }
        let xs = nodes.map(\.position.x), ys = nodes.map(\.position.y)
        return CGSize(width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    public static func extract(_ ids: Set<NodeID>, from graph: Graph) -> GraphClipboard {
        let picked = ids.compactMap { graph.nodes[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        guard !picked.isEmpty else { return GraphClipboard(nodes: [], edges: []) }
        let ox = picked.map(\.position.x).min()!, oy = picked.map(\.position.y).min()!
        let rel = picked.map { n -> NodeInstance in
            var m = n
            m.position = CGPoint(x: n.position.x - ox, y: n.position.y - oy)
            return m
        }
        return GraphClipboard(nodes: rel, edges: graph.internalEdges(among: ids), sourceOrigin: CGPoint(x: ox, y: oy))
    }

    /// Fresh IDs every call, so the same clipboard can be pasted repeatedly.
    public func materialize(at origin: CGPoint) -> (nodes: [NodeInstance], edges: [Edge]) {
        var map: [NodeID: NodeID] = [:]
        let fresh = nodes.map { n -> NodeInstance in
            let id = NodeID()
            map[n.id] = id
            return NodeInstance(id: id, kind: n.kind,
                                position: CGPoint(x: n.position.x + origin.x, y: n.position.y + origin.y),
                                params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        let wires = edges.compactMap { e -> Edge? in
            guard let to = map[e.to.node], let from = map[e.from.node] else { return nil }
            return Edge(to: SocketRef(to, e.to.socket), from: SocketRef(from, e.from.socket))
        }
        return (fresh, wires)
    }
}
