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

    private static func def(of node: NodeID, graph: Graph, registry: NodeRegistry) -> NodeDef? {
        guard let n = graph.nodes[node], case .builtin(let id) = n.kind else { return nil }
        return registry[id]
    }

    static func inputType(of ref: SocketRef, graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> SocketType? {
        guard let d = def(of: ref.node, graph: graph, registry: registry), let decl = d.input(named: ref.socket) else { return nil }
        if let t = resolved[ref.node]?.inputTypes[ref.socket] { return t }
        if case .concrete(let c) = decl.type { return c }
        return .float
    }

    static func outputType(of ref: SocketRef, graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> SocketType? {
        guard let d = def(of: ref.node, graph: graph, registry: registry), let decl = d.output(named: ref.socket) else { return nil }
        if let t = resolved[ref.node]?.outputTypes[ref.socket] { return t }
        if case .concrete(let c) = decl.type { return c }
        return .float
    }

    static func firstCompatibleInput(on node: NodeID, for type: SocketType, graph: Graph, registry: NodeRegistry,
                                     resolved: [NodeID: ResolvedNode]) -> SocketRef? {
        guard let d = def(of: node, graph: graph, registry: registry) else { return nil }
        for decl in d.inputs {
            let ref = SocketRef(node, decl.name)
            if let t = inputType(of: ref, graph: graph, registry: registry, resolved: resolved), compatible(type, t) { return ref }
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

    static func resolve(point: CGPoint, source: SocketRef, dragType: SocketType, anchors: [SocketRef: CGPoint],
                        graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> DropTarget {
        var best: (SocketRef, CGFloat)?
        for (ref, a) in anchors where ref.node != source.node {
            let d = hypot(a.x - point.x, a.y - point.y)
            guard d <= snapRadius, d < (best?.1 ?? .infinity) else { continue }
            guard let t = inputType(of: ref, graph: graph, registry: registry, resolved: resolved), compatible(dragType, t) else { continue }
            best = (ref, d)
        }
        if let (ref, _) = best { return .socket(ref) }

        for n in graph.nodes.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }).reversed()
        where n.id != source.node {
            if let f = NodeGeometry.frame(for: n, registry: registry), f.contains(point) { return .node(n.id) }
        }
        return .empty
    }
}
