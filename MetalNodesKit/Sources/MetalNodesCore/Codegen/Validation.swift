import Foundation

public enum GraphValidator {
    public static let fragmentTerminalID = "output.fragment"

    public static func terminal(in graph: Graph) -> NodeID? {
        graph.nodes.values
            .filter { $0.kind == .builtin(fragmentTerminalID) }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
            .first
    }

    public static func validate(_ graph: Graph, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] {
        var out: [Diagnostic] = []

        if case .stitchable = target {
            out.append(Diagnostic(.error, "SwiftUI stitchable output is not yet supported"))
        }

        // Definitions and kinds.
        var defs: [NodeID: NodeDef] = [:]
        for n in graph.nodes.values {
            switch n.kind {
            case .builtin(let id):
                if let d = registry[id] { defs[n.id] = d }
                else { out.append(Diagnostic(.error, "Unknown node type “\(id)”", node: n.id)) }
            case .group, .groupInput, .groupOutput:
                out.append(Diagnostic(.error, "Node groups are not yet supported", node: n.id))
            }
        }

        // Exactly one terminal.
        let terminals = graph.nodes.values.filter { $0.kind == .builtin(fragmentTerminalID) }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        if terminals.isEmpty {
            out.append(Diagnostic(.error, "Graph has no Fragment Output node"))
        }
        for extra in terminals.dropFirst() {
            out.append(Diagnostic(.error, "A graph may have only one Fragment Output", node: extra.id))
        }

        // Wire endpoints.
        for (to, from) in graph.inputs {
            guard let toDef = defs[to.node] else {
                if graph.nodes[to.node] == nil { out.append(Diagnostic(.error, "Wire ends at a missing node")) }
                continue
            }
            guard let fromDef = defs[from.node] else {
                if graph.nodes[from.node] == nil { out.append(Diagnostic(.error, "Wire starts at a missing node", node: to.node, socket: to.socket)) }
                continue
            }
            if toDef.input(named: to.socket) == nil {
                out.append(Diagnostic(.error, "No input socket named “\(to.socket)” on \(toDef.title)", node: to.node, socket: to.socket))
            }
            if fromDef.output(named: from.socket) == nil {
                out.append(Diagnostic(.error, "No output socket named “\(from.socket)” on \(fromDef.title)", node: from.node, socket: from.socket))
            }
        }

        // Cycles — iterative DFS with colouring.
        enum Mark { case visiting, done }
        var marks: [NodeID: Mark] = [:]
        func sources(of n: NodeID) -> [NodeID] {
            graph.inputs.filter { $0.key.node == n }.map(\.value.node).filter { graph.nodes[$0] != nil }
        }
        for start in graph.nodes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) where marks[start] == nil {
            var stack: [(NodeID, [NodeID])] = [(start, sources(of: start))]
            marks[start] = .visiting
            while let top = stack.last {
                let n = top.0
                var pending = top.1
                if let next = pending.popLast() {
                    stack[stack.count - 1] = (n, pending)
                    switch marks[next] {
                    case .visiting:
                        out.append(Diagnostic(.error, "Wires form a cycle", node: next))
                    case .done: break
                    case nil:
                        marks[next] = .visiting
                        stack.append((next, sources(of: next)))
                    }
                } else {
                    marks[n] = .done
                    stack.removeLast()
                }
            }
        }

        // Required inputs.
        for (id, def) in defs {
            for decl in def.inputs where decl.default == .required && graph.inputs[SocketRef(id, decl.name)] == nil {
                out.append(Diagnostic(.error, "“\(decl.label)” must be connected", node: id, socket: decl.name))
            }
        }
        return out
    }
}
