import Foundation

public struct ResolvedNode: Sendable, Hashable {
    public let id: NodeID
    public var generics: [String: SocketType]
    public var inputTypes: [String: SocketType]
    public var outputTypes: [String: SocketType]
}

public enum TypeResolver {
    public static func resolve(_ graph: Graph, path: GraphPath, document doc: ShaderDocument, registry: NodeRegistry, order: [NodeID])
        -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        var resolved: [NodeID: ResolvedNode] = [:]
        var diags: [Diagnostic] = []

        for id in order {
            guard let inst = graph.nodes[id], let def = doc.shape(of: inst, in: path, registry: registry) else { continue }

            // 1. Resolve each generic from the connected inputs that use it.
            var generics: [String: SocketType] = [:]
            for (name, allowed) in def.generics {
                let s = allowed.sorted { ($0.componentCount ?? 0) < ($1.componentCount ?? 0) }
                var sources: [SocketType] = []
                for decl in def.inputs where decl.type == .generic(name) {
                    guard let src = graph.inputs[SocketRef(id, decl.name)],
                          let srcType = resolved[src.node]?.outputTypes[src.socket] else { continue }
                    sources.append(srcType)
                }
                if let first = sources.first, sources.allSatisfy({ $0 == first }), allowed.contains(first) {
                    generics[name] = first                       // spec §19.5: exact match wins
                } else if let n = sources.map({ $0.componentCount ?? 0 }).max() {
                    generics[name] = s.first { ($0.componentCount ?? 0) >= n } ?? s.last ?? .float
                } else {
                    generics[name] = s.contains(.float) ? .float : (s.first ?? .float)
                }
            }

            func concrete(_ t: TypeRef) -> SocketType {
                switch t {
                case .concrete(let c): c
                case .generic(let g): generics[g] ?? .float
                }
            }
            // A pseudo-node's `+` is a gesture target, not a socket with a value: it gets no entry
            // here, so nothing downstream can mistake it for one (spec §20.6).
            let node = ResolvedNode(
                id: id, generics: generics,
                inputTypes: Dictionary(uniqueKeysWithValues: def.inputs.filter { !NodeShape.isPlus($0) }.map { ($0.name, concrete($0.type)) }),
                outputTypes: Dictionary(uniqueKeysWithValues: def.outputs.filter { !NodeShape.isPlus($0) }.map { ($0.name, concrete($0.type)) }))
            resolved[id] = node

            // 2. Every wire into this node must be convertible. The canvas turns a drop on a
            // pseudo-node's `+` into an exposed socket, so no wire should ever end there — and if
            // one does, it is not a conversion to complain about (spec §20.6).
            for decl in def.inputs where !NodeShape.isPlus(decl) {
                guard let src = graph.inputs[SocketRef(id, decl.name)],
                      let srcType = resolved[src.node]?.outputTypes[src.socket] else { continue }
                let dst = node.inputTypes[decl.name]!
                if ConversionRules.convert(from: srcType, to: dst) == nil {
                    diags.append(Diagnostic(.error, "Cannot connect \(srcType.rawValue) to \(dst.rawValue)", node: id, socket: decl.name))
                }
            }
        }
        return (resolved, diags)
    }

    /// Root-only convenience for existing callers.
    public static func resolve(_ graph: Graph, registry: NodeRegistry, order: [NodeID]) -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        var d = ShaderDocument(); d.root = graph
        return resolve(graph, path: .root, document: d, registry: registry, order: order)
    }
}
