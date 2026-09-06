import CoreGraphics
import MetalNodesCore

enum DropTarget: Equatable {
    case socket(SocketRef)
    case node(NodeID)
    case empty
}

/// Where a wire drag ends up (spec §18.5): socket → node body → empty canvas.
enum DropResolver {
    static let snapRadius: CGFloat = 14

    static func compatible(_ from: SocketType, _ to: SocketType) -> Bool {
        ConversionRules.convert(from: from, to: to) != nil
    }

    private static func shape(of node: NodeID, graph: Graph, shapes: (NodeInstance) -> NodeShape?) -> NodeShape? {
        graph.nodes[node].flatMap(shapes)
    }

    static func inputType(of ref: SocketRef, graph: Graph, shapes: (NodeInstance) -> NodeShape?,
                          resolved: [NodeID: ResolvedNode]) -> SocketType? {
        guard let s = shape(of: ref.node, graph: graph, shapes: shapes), let decl = s.input(named: ref.socket) else { return nil }
        if let t = resolved[ref.node]?.inputTypes[ref.socket] { return t }
        if case .concrete(let c) = decl.type { return c }
        return .float
    }

    static func outputType(of ref: SocketRef, graph: Graph, shapes: (NodeInstance) -> NodeShape?,
                           resolved: [NodeID: ResolvedNode]) -> SocketType? {
        guard let s = shape(of: ref.node, graph: graph, shapes: shapes), let decl = s.output(named: ref.socket) else { return nil }
        if let t = resolved[ref.node]?.outputTypes[ref.socket] { return t }
        if case .concrete(let c) = decl.type { return c }
        return .float
    }

    /// Whether a wire may end at `ref`. A pseudo-node's `+` takes anything a group socket can be —
    /// any non-texture type; `wildcard` is a drag from `GroupInput.+`, which has no type yet and so
    /// any non-texture input takes, the `+` sockets themselves excepted (spec §20.6).
    static func accepts(_ type: SocketType, at ref: SocketRef, wildcard: Bool = false, graph: Graph,
                        shapes: (NodeInstance) -> NodeShape?, resolved: [NodeID: ResolvedNode]) -> Bool {
        guard let s = shape(of: ref.node, graph: graph, shapes: shapes), let decl = s.input(named: ref.socket) else { return false }
        if NodeShape.isPlus(decl) { return !wildcard && type != .texture }
        guard let t = inputType(of: ref, graph: graph, shapes: shapes, resolved: resolved) else { return false }
        return wildcard ? t != .texture : compatible(type, t)
    }

    /// The input a drop on the node's body lands on. Never the `+` socket: exposing is a deliberate
    /// drop on it, not a fallback (spec §20.6).
    static func firstCompatibleInput(on node: NodeID, for type: SocketType, wildcard: Bool = false, graph: Graph,
                                     shapes: (NodeInstance) -> NodeShape?,
                                     resolved: [NodeID: ResolvedNode]) -> SocketRef? {
        guard let s = shape(of: node, graph: graph, shapes: shapes) else { return nil }
        for decl in s.inputs where !NodeShape.isPlus(decl) {
            let ref = SocketRef(node, decl.name)
            if accepts(type, at: ref, wildcard: wildcard, graph: graph, shapes: shapes, resolved: resolved) { return ref }
        }
        return nil
    }

    /// The closest socket anchor within `radius` of `point`, or nil.
    static func socket(near point: CGPoint, within radius: CGFloat, anchors: [SocketRef: CGPoint]) -> SocketRef? {
        var best: (SocketRef, CGFloat)?
        for (ref, a) in anchors {
            let d = hypot(a.x - point.x, a.y - point.y)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (ref, d) }
        }
        return best?.0
    }

    static func resolve(point: CGPoint, source: SocketRef, dragType: SocketType, wildcard: Bool = false,
                        anchors: [SocketRef: CGPoint], graph: Graph, shapes: (NodeInstance) -> NodeShape?,
                        resolved: [NodeID: ResolvedNode]) -> DropTarget {
        var best: (SocketRef, CGFloat)?
        for (ref, a) in anchors where ref.node != source.node {
            let d = hypot(a.x - point.x, a.y - point.y)
            guard d <= snapRadius, d < (best?.1 ?? .infinity) else { continue }
            guard accepts(dragType, at: ref, wildcard: wildcard, graph: graph, shapes: shapes, resolved: resolved) else { continue }
            best = (ref, d)
        }
        if let (ref, _) = best { return .socket(ref) }

        for n in graph.nodes.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }).reversed()
        where n.id != source.node {
            if let f = NodeGeometry.frame(for: n, shapes: shapes), f.contains(point) { return .node(n.id) }
        }
        return .empty
    }
}

// MARK: The `+` sockets

extension DropResolver {
    /// The `+` socket a drop exposes an output at: `GroupOutput`'s trailing input (spec §20.6).
    static func isPlusInput(_ ref: SocketRef, in graph: Graph) -> Bool {
        ref.socket == NodeShape.plusSocketName && graph.nodes[ref.node]?.kind == .groupOutput
    }

    /// The `+` socket a drag starts a wildcard from: `GroupInput`'s trailing output (spec §20.6).
    static func isPlusOutput(_ ref: SocketRef, in graph: Graph) -> Bool {
        ref.socket == NodeShape.plusSocketName && graph.nodes[ref.node]?.kind == .groupInput
    }
}
