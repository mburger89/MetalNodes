import Foundation

public enum GraphValidator {
    public static let fragmentTerminalID = "output.fragment"
    static let textureSampleID = "texture.sample"

    public static func terminal(in graph: Graph) -> NodeID? {
        graph.nodes.values
            .filter { $0.kind == .builtin(fragmentTerminalID) }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
            .first
    }

    /// The whole document: the root and every definition (spec §20.2, §20.4).
    public static func validate(document doc: ShaderDocument, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] {
        var out = validate(graph: doc.root, path: .root, document: doc, registry: registry)
        for d in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            out += validate(graph: d.graph, path: .definition(d.id), document: doc, registry: registry)
            if GroupDependencies.transitive(d.id, in: doc).contains(d.id) || GroupDependencies.direct(d).contains(d.id) {
                out.append(Diagnostic(.error, "Definition “\(d.name)” contains itself"))
            }
        }
        return out + textureTargetDiagnostics(doc, target: target)
    }

    /// What the SwiftUI targets make of Texture Sample (spec §21.2). Document-wide, because that is
    /// the scale each rule works at.
    private static func textureTargetDiagnostics(_ doc: ShaderDocument, target: OutputTarget) -> [Diagnostic] {
        guard case .stitchable(let kind) = target else { return [] }

        // The Layer Effect has a layer to sample instead of an asset, but only the exported
        // function can name it: a group function would take a `texture2d<float>` parameter that
        // nothing in the export could supply. So a sample inside a definition is refused — once per
        // node, since each is its own place to fix.
        //
        // Only definitions the export would actually emit, though: an unused definition (My
        // Functions keeps the one an ungroup leaves behind) reaches no `texture2d<float>` parameter
        // and would otherwise fail the whole document over a node the canvas cannot show.
        if kind == .layerEffect {
            let reachable = GroupDependencies.reachable(from: doc.root, in: doc)
            return reachable.sorted { $0.raw.uuidString < $1.raw.uuidString }
                .compactMap { doc.definitions[$0] }
                .flatMap { samples(in: $0.graph) }
                .map { Diagnostic(.error, "Texture Sample inside a group needs the Fragment target", node: $0) }
        }

        // A Color or Distortion Effect gets no texture argument from SwiftUI and has no layer
        // either, so it refuses Texture Sample outright. That is a property of the target rather
        // than of any one node, hence a single diagnostic however many samples the document holds —
        // anchored on one in the root when there is one, so the reader is pointed at a node the
        // canvas actually shows.
        let anchor = samples(in: doc.root).first ?? doc.definitions.values
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
            .lazy.flatMap { samples(in: $0.graph) }.first
        guard let anchor else { return [] }
        return [Diagnostic(.error, "Texture Sample needs the Layer Effect target", node: anchor)]
    }

    /// Every Texture Sample in `graph`, ordered by id so a diagnostic always names the same one.
    private static func samples(in graph: Graph) -> [NodeID] {
        graph.nodes.values
            .filter { $0.kind == .builtin(textureSampleID) }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
    }

    public static func validate(graph: Graph, path: GraphPath, document doc: ShaderDocument, registry: NodeRegistry) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var shapes: [NodeID: NodeShape] = [:]
        let sorted = graph.nodes.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        for n in sorted {
            switch n.kind {
            case .builtin(let id) where registry[id] == nil:
                out.append(Diagnostic(.error, "Unknown node type “\(id)”", node: n.id))
            case .group(let g) where doc.definitions[g] == nil:
                out.append(Diagnostic(.error, "Group definition is missing", node: n.id))
            case .groupInput where path == .root:
                out.append(Diagnostic(.error, "Group Input is only valid inside a definition", node: n.id))
            case .groupOutput where path == .root:
                out.append(Diagnostic(.error, "Group Output is only valid inside a definition", node: n.id))
            default:
                if let s = doc.shape(of: n, in: path, registry: registry) { shapes[n.id] = s }
            }
        }

        // Terminals.
        switch path {
        case .root:
            let terminals = sorted.filter { $0.kind == .builtin(fragmentTerminalID) }
            if terminals.isEmpty { out.append(Diagnostic(.error, "Graph has no Fragment Output node")) }
            for extra in terminals.dropFirst() { out.append(Diagnostic(.error, "A graph may have only one Fragment Output", node: extra.id)) }
        case .definition(let gid):
            let name = doc.definitions[gid]?.name ?? "?"
            for n in sorted where n.kind == .builtin(fragmentTerminalID) {
                out.append(Diagnostic(.error, "Fragment Output is only valid in the root graph", node: n.id))
            }
            let ins = sorted.filter { $0.kind == .groupInput }, outs = sorted.filter { $0.kind == .groupOutput }
            if ins.isEmpty { out.append(Diagnostic(.error, "Definition “\(name)” has no Group Input")) }
            if outs.isEmpty { out.append(Diagnostic(.error, "Definition “\(name)” has no Group Output")) }
            // No pseudo-node is more "canonical" than another, so every one of a duplicate set is flagged
            // (unlike the root Fragment Output check above, which keeps an arbitrary first as the real terminal).
            if ins.count > 1 { for extra in ins { out.append(Diagnostic(.error, "A definition may have only one Group Input", node: extra.id)) } }
            if outs.count > 1 { for extra in outs { out.append(Diagnostic(.error, "A definition may have only one Group Output", node: extra.id)) } }
        }

        // Wire endpoints — same checks as before, against shapes.
        for (to, from) in graph.inputs.sorted(by: { ($0.key.node.raw.uuidString, $0.key.socket) < ($1.key.node.raw.uuidString, $1.key.socket) }) {
            guard let toShape = shapes[to.node] else {
                if graph.nodes[to.node] == nil { out.append(Diagnostic(.error, "Wire ends at a missing node")) }
                continue
            }
            guard let fromShape = shapes[from.node] else {
                if graph.nodes[from.node] == nil { out.append(Diagnostic(.error, "Wire starts at a missing node", node: to.node, socket: to.socket)) }
                continue
            }
            if toShape.input(named: to.socket) == nil {
                out.append(Diagnostic(.error, "No input socket named “\(to.socket)” on \(toShape.title)", node: to.node, socket: to.socket))
            }
            if fromShape.output(named: from.socket) == nil {
                out.append(Diagnostic(.error, "No output socket named “\(from.socket)” on \(fromShape.title)", node: from.node, socket: from.socket))
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

        // Required inputs — a `.required` input on a pseudo-node or instance must be wired too.
        // A pseudo-node's `+` is a gesture target, not a socket anyone owes a wire (spec §20.6).
        for (id, s) in shapes.sorted(by: { $0.key.raw.uuidString < $1.key.raw.uuidString }) {
            for decl in s.inputs where !NodeShape.isPlus(decl) && decl.default == .required && graph.inputs[SocketRef(id, decl.name)] == nil {
                out.append(Diagnostic(.error, "“\(decl.label)” must be connected", node: id, socket: decl.name))
            }
        }

        // Enum param values must be a valid case of the declared enumeration.
        for (id, s) in shapes.sorted(by: { $0.key.raw.uuidString < $1.key.raw.uuidString }) {
            guard let inst = graph.nodes[id] else { continue }
            for p in s.params {
                guard case .enumeration(let cases) = p.kind,
                      case .enumCase(let c)? = inst.params[p.name],
                      !cases.contains(c) else { continue }
                out.append(Diagnostic(.error, "“\(c)” is not a valid option for \(p.label)", node: id, socket: p.name))
            }
        }
        return out
    }

    /// A viewer must name an existing node's output of a viewable (non-texture) type — in any graph.
    /// A `GroupInput`'s `+` is an output in shape only and carries no value (spec §20.6).
    public static func isValidViewer(_ ref: SocketRef, in doc: ShaderDocument, registry: NodeRegistry) -> Bool {
        guard let s = doc.shape(of: ref.node, registry: registry), let decl = s.output(named: ref.socket),
              !NodeShape.isPlus(decl) else { return false }
        if case .concrete(.texture) = decl.type { return false }
        return true
    }

    /// Root-only convenience, kept for existing callers.
    public static func isValidViewer(_ ref: SocketRef, in graph: Graph, registry: NodeRegistry) -> Bool {
        var d = ShaderDocument(); d.root = graph
        return isValidViewer(ref, in: d, registry: registry)
    }
}
