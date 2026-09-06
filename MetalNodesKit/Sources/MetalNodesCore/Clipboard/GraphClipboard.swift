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
    /// Manifest entries for every `.asset` referenced by a copied node or by a node inside a
    /// carried definition (spec §13, §21.2). Present even when `textures` lacks the bytes.
    public var assetInfos: [AssetID: AssetInfo] = [:]
    /// Bytes for the assets above, when the source had them (never re-encoded).
    public var textures: [AssetID: Data] = [:]

    public init(nodes: [NodeInstance], edges: [Edge], sourceOrigin: CGPoint = .zero) {
        self.nodes = nodes
        self.edges = edges
        self.sourceOrigin = sourceOrigin
    }

    /// Nothing to paste. Comments count: a note copies on its own (spec §21.4).
    public var isEmpty: Bool { nodes.isEmpty && stickies.isEmpty && frames.isEmpty }

    /// Extent of the relative node positions (top-left of each node; excludes node size).
    public var size: CGSize {
        guard !nodes.isEmpty else { return .zero }
        let xs = nodes.map(\.position.x), ys = nodes.map(\.position.y)
        return CGSize(width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The selected nodes and comments, positioned relative to the payload's own top-left — which
    /// spans both, so a note above the nodes keeps its offset from them (spec §21.4).
    public static func extract(_ ids: Set<NodeID>, comments: Set<CommentID> = [], from graph: Graph) -> GraphClipboard {
        let picked = ids.compactMap { graph.nodes[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        let notes = comments.compactMap { id -> StickyNote? in
            guard case .sticky(let s) = id else { return nil }
            return graph.stickies[s]
        }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        let boxes = comments.compactMap { id -> CommentFrame? in
            guard case .frame(let f) = id else { return nil }
            return graph.frames[f]
        }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        let origins = picked.map(\.position) + notes.map(\.frame.origin) + boxes.map(\.frame.origin)
        guard let ox = origins.map(\.x).min(), let oy = origins.map(\.y).min() else {
            return GraphClipboard(nodes: [], edges: [])
        }
        let rel = picked.map { n -> NodeInstance in
            var m = n
            m.position = CGPoint(x: n.position.x - ox, y: n.position.y - oy)
            return m
        }
        var clip = GraphClipboard(nodes: rel, edges: graph.internalEdges(among: ids), sourceOrigin: CGPoint(x: ox, y: oy))
        clip.stickies = notes.map { var m = $0; m.frame.origin = CGPoint(x: $0.frame.minX - ox, y: $0.frame.minY - oy); return m }
        clip.frames = boxes.map { var m = $0; m.frame.origin = CGPoint(x: $0.frame.minX - ox, y: $0.frame.minY - oy); return m }
        return clip
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

    /// The comments, with fresh ids and absolute rects — the counterpart of `materialize`, kept
    /// apart so a node-only paste never has to unpack a pair it does not use (spec §21.4).
    public func materializeComments(at origin: CGPoint) -> (stickies: [StickyNote], frames: [CommentFrame]) {
        (stickies.map { StickyNote(text: $0.text, frame: $0.frame.offsetBy(dx: origin.x, dy: origin.y), accent: $0.accent) },
         frames.map { CommentFrame(title: $0.title, frame: $0.frame.offsetBy(dx: origin.x, dy: origin.y),
                                   accent: $0.accent, collapsed: $0.collapsed) })
    }
}

public extension GraphClipboard {
    /// Spec §6, §20.7: the payload also carries every `GroupDefinition` transitively referenced
    /// by the copied instances, sorted by id. Pseudo-nodes (`.groupInput`/`.groupOutput`) never copy.
    ///
    /// Spec §13, §21.2: also carries every asset (manifest entry, and bytes when `textures` has
    /// them) referenced by a `.asset` param on a copied node or on any node inside a carried
    /// definition — the carried definitions already are the transitive closure, so no further
    /// recursion is needed to reach nested ones. `comments` are carried as-is (spec §21.4).
    static func extract(_ ids: Set<NodeID>, comments: Set<CommentID> = [],
                        from graph: Graph, document doc: ShaderDocument,
                        textures: [AssetID: Data] = [:]) -> GraphClipboard {
        let real = ids.filter { graph.nodes[$0].map { $0.kind != .groupInput && $0.kind != .groupOutput } ?? false }
        var clip = extract(real, comments: comments, from: graph)
        var refs = Set<GroupID>()
        for id in real {
            if case .group(let g)? = graph.nodes[id]?.kind {
                refs.insert(g)
                refs.formUnion(GroupDependencies.transitive(g, in: doc))
            }
        }
        clip.definitions = refs.compactMap { doc.definitions[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }

        var assetIDs = Set<AssetID>()
        func scan<S: Sequence>(_ nodes: S) where S.Element == NodeInstance {
            for n in nodes {
                for v in n.params.values {
                    if case .asset(let id?) = v { assetIDs.insert(id) }
                }
            }
        }
        scan(clip.nodes)
        for d in clip.definitions { scan(d.graph.nodes.values) }
        for id in assetIDs {
            if let info = doc.settings.assets[id] { clip.assetInfos[id] = info }
            if let data = textures[id] { clip.textures[id] = data }
        }
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
    private enum Keys: String, CodingKey {
        case formatVersion, sourceOrigin, nodes, edges, stickies, frames, definitions, assetInfos, textures
    }

    /// Tolerant decoding: every key but the payload itself is optional, so a clipboard written by
    /// an older build (or one that predates `stickies`/`frames`/`definitions`/`assetInfos`/`textures`)
    /// still pastes. Encoding stays synthesized, so a round trip is unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? GraphClipboard.currentFormatVersion
        sourceOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .sourceOrigin) ?? .zero
        nodes = try c.decodeIfPresent([NodeInstance].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        stickies = try c.decodeIfPresent([StickyNote].self, forKey: .stickies) ?? []
        frames = try c.decodeIfPresent([CommentFrame].self, forKey: .frames) ?? []
        definitions = try c.decodeIfPresent([GroupDefinition].self, forKey: .definitions) ?? []
        assetInfos = try c.decodeIfPresent([AssetID: AssetInfo].self, forKey: .assetInfos) ?? [:]
        textures = try c.decodeIfPresent([AssetID: Data].self, forKey: .textures) ?? [:]
    }
}
