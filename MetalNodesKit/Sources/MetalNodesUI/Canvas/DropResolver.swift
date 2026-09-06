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

    static func firstCompatibleInput(on node: NodeID, for type: SocketType, graph: Graph,
                                     shapes: (NodeInstance) -> NodeShape?,
                                     resolved: [NodeID: ResolvedNode]) -> SocketRef? {
        guard let s = shape(of: node, graph: graph, shapes: shapes) else { return nil }
        for decl in s.inputs {
            let ref = SocketRef(node, decl.name)
            if let t = inputType(of: ref, graph: graph, shapes: shapes, resolved: resolved), compatible(type, t) { return ref }
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
                        graph: Graph, shapes: (NodeInstance) -> NodeShape?,
                        resolved: [NodeID: ResolvedNode]) -> DropTarget {
        var best: (SocketRef, CGFloat)?
        for (ref, a) in anchors where ref.node != source.node {
            let d = hypot(a.x - point.x, a.y - point.y)
            guard d <= snapRadius, d < (best?.1 ?? .infinity) else { continue }
            guard let t = inputType(of: ref, graph: graph, shapes: shapes, resolved: resolved), compatible(dragType, t) else { continue }
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

// MARK: Registry entry points

/// As in `NodeGeometry`: for callers holding a bare `Graph` read as a document root.
extension DropResolver {
    static func inputType(of ref: SocketRef, graph: Graph, registry: NodeRegistry,
                          resolved: [NodeID: ResolvedNode]) -> SocketType? {
        inputType(of: ref, graph: graph, shapes: NodeGeometry.rootShapes(in: graph, registry: registry), resolved: resolved)
    }

    static func outputType(of ref: SocketRef, graph: Graph, registry: NodeRegistry,
                           resolved: [NodeID: ResolvedNode]) -> SocketType? {
        outputType(of: ref, graph: graph, shapes: NodeGeometry.rootShapes(in: graph, registry: registry), resolved: resolved)
    }

    static func firstCompatibleInput(on node: NodeID, for type: SocketType, graph: Graph, registry: NodeRegistry,
                                     resolved: [NodeID: ResolvedNode]) -> SocketRef? {
        firstCompatibleInput(on: node, for: type, graph: graph,
                             shapes: NodeGeometry.rootShapes(in: graph, registry: registry), resolved: resolved)
    }

    static func resolve(point: CGPoint, source: SocketRef, dragType: SocketType, anchors: [SocketRef: CGPoint],
                        graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> DropTarget {
        resolve(point: point, source: source, dragType: dragType, anchors: anchors, graph: graph,
                shapes: NodeGeometry.rootShapes(in: graph, registry: registry), resolved: resolved)
    }
}
