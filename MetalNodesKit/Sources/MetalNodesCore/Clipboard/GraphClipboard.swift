import Foundation
import CoreGraphics

/// The pasteboard payload (spec §6, §18.4): a subgraph with positions relative to its own
/// bounding box, plus the group definitions it transitively depends on (populated by
/// `extract(_:from:document:)`).
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

public extension GraphClipboard {
    /// Spec §6, §20.7: the payload also carries every `GroupDefinition` transitively referenced
    /// by the copied instances, sorted by id. Pseudo-nodes (`.groupInput`/`.groupOutput`) never copy.
    static func extract(_ ids: Set<NodeID>, from graph: Graph, document doc: ShaderDocument) -> GraphClipboard {
        let real = ids.filter { graph.nodes[$0].map { $0.kind != .groupInput && $0.kind != .groupOutput } ?? false }
        var clip = extract(real, from: graph)
        var refs = Set<GroupID>()
        for id in real {
            if case .group(let g)? = graph.nodes[id]?.kind {
                refs.insert(g)
                refs.formUnion(GroupDependencies.transitive(g, in: doc))
            }
        }
        clip.definitions = refs.compactMap { doc.definitions[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        return clip
    }
}

/// Spec §6 / §20.7: what to do with the definitions a paste payload brings — reuse an identical
/// definition, import a diverged one under a fresh id, or insert one the destination lacks.
public enum ClipboardMerge {
    public struct Plan: Sendable {
        public var insert: [GroupDefinition] = []
        public var remap: [GroupID: GroupID] = [:]
    }

    public static func plan(definitions: [GroupDefinition], into doc: ShaderDocument) -> Plan {
        var plan = Plan()
        for d in definitions {
            if let existing = doc.definitions[d.id] {
                if existing.contentHash == d.contentHash { continue }
                let copy = d.duplicate(name: d.name + " (imported)")
                plan.remap[d.id] = copy.id
                plan.insert.append(copy)
            } else {
                plan.insert.append(d)
            }
        }
        // Instances inside inserted definitions must follow the remap too.
        plan.insert = plan.insert.map { d in
            var m = d
            for (id, n) in m.graph.nodes {
                if case .group(let g) = n.kind, let r = plan.remap[g] { m.graph.nodes[id]!.kind = .group(r) }
            }
            return m
        }
        return plan
    }

    public static func apply(_ plan: Plan, to nodes: [NodeInstance]) -> [NodeInstance] {
        nodes.map { n in
            var m = n
            if case .group(let g) = n.kind, let r = plan.remap[g] { m.kind = .group(r) }
            return m
        }
    }
}

extension GraphClipboard {
    private enum Keys: String, CodingKey { case formatVersion, sourceOrigin, nodes, edges, stickies, frames, definitions }

    /// Tolerant decoding: every key but the payload itself is optional, so a clipboard written by
    /// an older build (or one that predates `stickies`/`frames`/`definitions`) still pastes.
    /// Encoding stays synthesized, so a round trip is unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? GraphClipboard.currentFormatVersion
        sourceOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .sourceOrigin) ?? .zero
        nodes = try c.decodeIfPresent([NodeInstance].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        stickies = try c.decodeIfPresent([StickyNote].self, forKey: .stickies) ?? []
        frames = try c.decodeIfPresent([CommentFrame].self, forKey: .frames) ?? []
        definitions = try c.decodeIfPresent([GroupDefinition].self, forKey: .definitions) ?? []
    }
}
