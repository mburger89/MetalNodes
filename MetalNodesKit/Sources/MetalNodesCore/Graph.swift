import Foundation
import CoreGraphics

/// A socket on a specific node, addressed by **name** (spec §3).
public struct SocketRef: Hashable, Codable, Sendable {
    public var node: NodeID
    public var socket: String
    public init(_ node: NodeID, _ socket: String) { self.node = node; self.socket = socket }
}

public enum NodeKind: Hashable, Codable, Sendable {
    case builtin(String)
    case group(GroupID)
    case groupInput
    case groupOutput
}

public struct NodeInstance: Codable, Sendable, Hashable, Identifiable {
    public let id: NodeID
    public var kind: NodeKind
    public var position: CGPoint
    /// Unconnected input values and declared parameters, keyed by socket/param name.
    public var params: [ParamID: ParamValue]
    public var customTitle: String?
    public var collapsed: Bool

    public init(id: NodeID = NodeID(), kind: NodeKind, position: CGPoint = .zero,
                params: [ParamID: ParamValue] = [:], customTitle: String? = nil, collapsed: Bool = false) {
        self.id = id; self.kind = kind; self.position = position
        self.params = params; self.customTitle = customTitle; self.collapsed = collapsed
    }
}

public enum DraculaAccent: String, Codable, Sendable, CaseIterable {
    case cyan, green, orange, pink, purple, yellow, muted
}

public struct StickyNote: Codable, Sendable, Hashable, Identifiable {
    public let id: StickyID
    public var text: String
    public var frame: CGRect
    public var accent: DraculaAccent
    public init(id: StickyID = StickyID(), text: String, frame: CGRect, accent: DraculaAccent = .muted) {
        self.id = id; self.text = text; self.frame = frame; self.accent = accent
    }
}

public struct CommentFrame: Codable, Sendable, Hashable, Identifiable {
    public let id: FrameID
    public var title: String
    public var frame: CGRect
    public var accent: DraculaAccent
    public var collapsed: Bool
    public init(id: FrameID = FrameID(), title: String, frame: CGRect, accent: DraculaAccent = .muted, collapsed: Bool = false) {
        self.id = id; self.title = title; self.frame = frame; self.accent = accent; self.collapsed = collapsed
    }
}

/// One wire. `to` is the input socket (unique per graph), `from` its source output.
public struct Edge: Codable, Sendable, Hashable {
    public var to: SocketRef
    public var from: SocketRef
    public init(to: SocketRef, from: SocketRef) { self.to = to; self.from = from }
}

/// Nodes plus wires. Wires are stored **input → output** so each input has at
/// most one source by construction (spec §3).
public struct Graph: Sendable, Hashable {
    public var nodes: [NodeID: NodeInstance] = [:]
    public var inputs: [SocketRef: SocketRef] = [:]
    public var stickies: [StickyID: StickyNote] = [:]
    public var frames: [FrameID: CommentFrame] = [:]

    public init() {}

    public func source(feeding input: SocketRef) -> SocketRef? { inputs[input] }

    public mutating func connect(_ from: SocketRef, to input: SocketRef) { inputs[input] = from }

    public mutating func disconnect(_ input: SocketRef) { inputs[input] = nil }

    public mutating func remove(node id: NodeID) {
        nodes[id] = nil
        inputs = inputs.filter { $0.key.node != id && $0.value.node != id }
    }

    /// All wires touching a node, as (input, source) pairs.
    public func edges(of id: NodeID) -> [(to: SocketRef, from: SocketRef)] {
        inputs.filter { $0.key.node == id || $0.value.node == id }.map { (to: $0.key, from: $0.value) }
    }

    public func upstreamNodes(of id: NodeID) -> Set<NodeID> {
        var seen = Set<NodeID>()
        var stack = [id]
        while let n = stack.popLast() {
            for (to, from) in inputs where to.node == n {
                if seen.insert(from.node).inserted { stack.append(from.node) }
            }
        }
        return seen
    }

    /// Every wire, sorted by input socket so output is deterministic.
    public var edgeList: [Edge] {
        inputs.map { Edge(to: $0.key, from: $0.value) }
            .sorted { ($0.to.node.raw.uuidString, $0.to.socket) < ($1.to.node.raw.uuidString, $1.to.socket) }
    }

    /// Wires whose both ends are inside `ids` — the edges a copy/group operation keeps.
    public func internalEdges(among ids: Set<NodeID>) -> [Edge] {
        edgeList.filter { ids.contains($0.to.node) && ids.contains($0.from.node) }
    }

    /// Removes several nodes and every wire touching any of them.
    public mutating func remove(nodes ids: Set<NodeID>) {
        for id in ids { nodes[id] = nil }
        inputs = inputs.filter { !ids.contains($0.key.node) && !ids.contains($0.value.node) }
    }
}

extension Graph: Codable {
    private enum Keys: String, CodingKey { case nodes, edges, stickies, frames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        nodes = Dictionary(uniqueKeysWithValues: try c.decode([NodeInstance].self, forKey: .nodes).map { ($0.id, $0) })
        inputs = Dictionary(uniqueKeysWithValues: try c.decode([Edge].self, forKey: .edges).map { ($0.to, $0.from) })
        stickies = Dictionary(uniqueKeysWithValues: try c.decodeIfPresent([StickyNote].self, forKey: .stickies)?.map { ($0.id, $0) } ?? [])
        frames = Dictionary(uniqueKeysWithValues: try c.decodeIfPresent([CommentFrame].self, forKey: .frames)?.map { ($0.id, $0) } ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(nodes.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .nodes)
        try c.encode(edgeList, forKey: .edges)
        try c.encode(stickies.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .stickies)
        try c.encode(frames.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .frames)
    }
}
