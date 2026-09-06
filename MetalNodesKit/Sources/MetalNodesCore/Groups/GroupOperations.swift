import Foundation
import CoreGraphics

public enum SocketKind: Sendable, Hashable { case input, output }

/// The five operations (spec §4, §20.6) as pure document transforms.
public enum GroupOperations {
    static let internalOffset = CGPoint(x: 220, y: 0)

    public static func isUsed(_ id: GroupID, in doc: ShaderDocument) -> Bool {
        func has(_ g: Graph) -> Bool { g.nodes.values.contains { $0.kind == .group(id) } }
        return has(doc.root) || doc.definitions.values.contains { has($0.graph) }
    }

    public static func uniqueDefinitionName(_ base: String, in doc: ShaderDocument) -> String {
        let names = Set(doc.definitions.values.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    public static func uniqueSocketName(_ base: String, among existing: [String]) -> String {
        let b = StitchableCodegen.sanitizedName(base)
        if !existing.contains(b) { return b }
        var n = 2
        while existing.contains("\(b)\(n)") { n += 1 }
        return "\(b)\(n)"
    }

    public static func group(_ ids: Set<NodeID>, in path: GraphPath, of doc: ShaderDocument, registry: NodeRegistry,
                             name: String?) -> (document: ShaderDocument, definition: GroupID, instance: NodeID)? {
        let g = doc[path]
        let picked = ids.compactMap { g.nodes[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        guard picked.count == ids.count, !picked.isEmpty,
              !picked.contains(where: { $0.kind == .groupInput || $0.kind == .groupOutput }) else { return nil }
        // Recursion: grouping inside definition D a selection that instantiates an ancestor of D is impossible
        // by construction (D would already contain itself), but a nested instance of D itself must be refused.
        if case .definition(let host) = path, picked.contains(where: { $0.kind == .group(host) }) { return nil }

        // Type every node in the graph at `path` — not just what a caller happened to resolve
        // already — so a boundary source inside a definition, or one with no path to any output,
        // still gets its real type (spec §20.6). An unknown type refuses the group rather than
        // silently guessing `.float`.
        let order = TopoSort.orderAll(g)
        let resolved = TypeResolver.resolve(g, path: path, document: doc, registry: registry, order: order).nodes
        func outType(_ ref: SocketRef) -> SocketType? { resolved[ref.node]?.outputTypes[ref.socket] }

        var def = GroupDefinition.make(name: uniqueDefinitionName(name ?? "Group", in: doc))
        guard let gin = def.inputNode, let gout = def.outputNode else { return nil }
        let minX = picked.map(\.position.x).min()!, minY = picked.map(\.position.y).min()!
        let maxX = picked.map(\.position.x).max()!
        for n in picked {
            var m = n
            m.position = CGPoint(x: n.position.x - minX + internalOffset.x, y: n.position.y - minY + internalOffset.y)
            def.graph.nodes[m.id] = m
        }
        def.graph.nodes[gout]!.position = CGPoint(x: maxX - minX + internalOffset.x + 260, y: 0)
        for e in g.internalEdges(among: ids) { def.graph.connect(e.from, to: e.to) }

        // Inbound: to ∈ S, from ∉ S — one input per distinct source socket.
        var inputBySource: [SocketRef: String] = [:]
        for (to, from) in g.inputs.sorted(by: { ($0.key.node.raw.uuidString, $0.key.socket) < ($1.key.node.raw.uuidString, $1.key.socket) })
        where ids.contains(to.node) && !ids.contains(from.node) {
            if inputBySource[from] == nil {
                guard let t = outType(from) else { return nil }
                let n = uniqueSocketName(from.socket, among: def.inputs.map(\.name))
                def.inputs.append(SocketDecl(name: n, type: .concrete(t), default: .value(zero(t))))
                inputBySource[from] = n
            }
            def.graph.connect(SocketRef(gin, inputBySource[from]!), to: to)
        }
        // Outbound: from ∈ S, to ∉ S — one output per distinct internal source socket.
        var outputBySource: [SocketRef: String] = [:]
        for (to, from) in g.inputs.sorted(by: { ($0.key.node.raw.uuidString, $0.key.socket) < ($1.key.node.raw.uuidString, $1.key.socket) })
        where ids.contains(from.node) && !ids.contains(to.node) {
            if outputBySource[from] == nil {
                guard let t = outType(from) else { return nil }
                let n = uniqueSocketName(from.socket, among: def.outputs.map(\.name))
                def.outputs.append(SocketDecl(name: n, type: .concrete(t)))
                outputBySource[from] = n
                def.graph.connect(from, to: SocketRef(gout, n))
            }
        }

        var out = doc
        out.definitions[def.id] = def
        var graph = g
        graph.remove(nodes: ids)
        let inst = NodeInstance(kind: .group(def.id), position: CGPoint(x: minX, y: minY))
        graph.nodes[inst.id] = inst
        for (from, name) in inputBySource { graph.connect(from, to: SocketRef(inst.id, name)) }
        for (to, from) in g.inputs where ids.contains(from.node) && !ids.contains(to.node) {
            graph.connect(SocketRef(inst.id, outputBySource[from]!), to: to)
        }
        out[path] = graph
        return (out, def.id, inst.id)
    }

    public static func ungroup(_ instance: NodeID, in path: GraphPath, of doc: ShaderDocument) -> (document: ShaderDocument, nodes: Set<NodeID>)? {
        var g = doc[path]
        guard let inst = g.nodes[instance], case .group(let gid) = inst.kind, let def = doc.definitions[gid],
              let gin = def.inputNode, let gout = def.outputNode else { return nil }
        var map: [NodeID: NodeID] = [:]
        for n in def.graph.nodes.values where n.id != gin && n.id != gout {
            let id = NodeID(); map[n.id] = id
            g.nodes[id] = NodeInstance(id: id, kind: n.kind,
                                       position: CGPoint(x: n.position.x - internalOffset.x + inst.position.x, y: n.position.y - internalOffset.y + inst.position.y),
                                       params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        // Internal wires between real nodes.
        for (to, from) in def.graph.inputs where map[to.node] != nil && map[from.node] != nil {
            g.connect(SocketRef(map[from.node]!, from.socket), to: SocketRef(map[to.node]!, to.socket))
        }
        // Inputs: whatever fed the instance's input socket now feeds every internal target of GroupInput.<name>;
        // unwired ones carry the instance's stored value (or the declared default) onto the internal input.
        for decl in def.inputs {
            let external = g.inputs[SocketRef(instance, decl.name)]
            for (to, from) in def.graph.inputs where from == SocketRef(gin, decl.name) {
                guard let target = map[to.node] else { continue }
                if let ext = external {
                    g.connect(ext, to: SocketRef(target, to.socket))
                } else {
                    let value: ParamValue? = inst.params[decl.name] ?? {
                        if case .value(let v) = decl.default { return v } else { return nil }
                    }()
                    if let value { g.nodes[target]!.params[to.socket] = value }
                }
            }
        }
        // Outputs: whatever fed GroupOutput.<name> now feeds every external target of the instance's output.
        // A pass-through (GroupOutput fed directly by GroupInput, with no real node in between) has no
        // inlined source to point at — the target instead picks up whatever fed the instance's own input.
        for decl in def.outputs {
            guard let internalSource = def.graph.inputs[SocketRef(gout, decl.name)] else { continue }
            let resolvedSource: SocketRef?
            if internalSource.node == gin {
                resolvedSource = g.inputs[SocketRef(instance, internalSource.socket)]
            } else if let src = map[internalSource.node] {
                resolvedSource = SocketRef(src, internalSource.socket)
            } else {
                resolvedSource = nil
            }
            guard let resolvedSource else { continue }
            for (to, from) in g.inputs where from == SocketRef(instance, decl.name) {
                g.connect(resolvedSource, to: to)
            }
        }
        g.remove(nodes: [instance])
        var out = doc
        out[path] = g
        return (out, Set(map.values))
    }

    public static func makeUnique(_ instance: NodeID, in path: GraphPath, of doc: ShaderDocument) -> (document: ShaderDocument, definition: GroupID)? {
        guard let inst = doc[path].nodes[instance], case .group(let gid) = inst.kind, let def = doc.definitions[gid] else { return nil }
        let copy = def.duplicate(name: uniqueDefinitionName(def.name + " 2", in: doc))
        var out = doc
        out.definitions[copy.id] = copy
        out[path].nodes[instance]!.kind = .group(copy.id)
        return (out, copy.id)
    }

    public static func rename(_ id: GroupID, to name: String, in doc: ShaderDocument) -> ShaderDocument? {
        guard doc.definitions[id] != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var out = doc; out.definitions[id]!.name = name; return out
    }

    public static func setAccent(_ id: GroupID, _ accent: DraculaAccent, in doc: ShaderDocument) -> ShaderDocument? {
        guard doc.definitions[id] != nil else { return nil }
        var out = doc; out.definitions[id]!.accent = accent; return out
    }

    public static func addSocket(_ id: GroupID, kind: SocketKind, decl: SocketDecl, in doc: ShaderDocument) -> ShaderDocument? {
        guard var def = doc.definitions[id] else { return nil }
        var d = decl
        // Inputs and outputs are separate namespaces (spec §20.6, ruling R11) — codegen keeps them apart.
        let existing = (kind == .input ? def.inputs : def.outputs).map(\.name)
        d.name = uniqueSocketName(decl.name, among: existing)
        if kind == .input { def.inputs.append(d) } else { def.outputs.append(d) }
        var out = doc; out.definitions[id] = def; return out
    }

    /// Renames everywhere (spec §20.6). Nil on an unknown socket or a clash (within the same
    /// namespace — inputs and outputs are separate, ruling R11) after sanitising.
    public static func renameSocket(_ id: GroupID, kind: SocketKind, from old: String, to newName: String, in doc: ShaderDocument) -> ShaderDocument? {
        guard var def = doc.definitions[id], let gin = def.inputNode, let gout = def.outputNode else { return nil }
        let names = (kind == .input ? def.inputs : def.outputs).map(\.name)
        guard names.contains(old) else { return nil }
        let new = StitchableCodegen.sanitizedName(newName)
        guard new != old else { return doc }
        guard !names.contains(new) else { return nil }
        switch kind {
        case .input:
            guard let i = def.inputs.firstIndex(where: { $0.name == old }) else { return nil }
            def.inputs[i].name = new
            def.graph.inputs = Dictionary(uniqueKeysWithValues: def.graph.inputs.map { to, from in
                (to, from == SocketRef(gin, old) ? SocketRef(gin, new) : from)
            })
        case .output:
            guard let i = def.outputs.firstIndex(where: { $0.name == old }) else { return nil }
            def.outputs[i].name = new
            if let f = def.graph.inputs[SocketRef(gout, old)] { def.graph.inputs[SocketRef(gout, old)] = nil; def.graph.inputs[SocketRef(gout, new)] = f }
        }
        var out = doc
        out.definitions[id] = def
        // Every instance, in every graph.
        func rewrite(_ g: inout Graph) {
            for n in g.nodes.values where n.kind == .group(id) {
                switch kind {
                case .input:
                    if let f = g.inputs[SocketRef(n.id, old)] { g.inputs[SocketRef(n.id, old)] = nil; g.inputs[SocketRef(n.id, new)] = f }
                    if let v = g.nodes[n.id]!.params[old] { g.nodes[n.id]!.params[old] = nil; g.nodes[n.id]!.params[new] = v }
                case .output:
                    g.inputs = Dictionary(uniqueKeysWithValues: g.inputs.map { to, from in (to, from == SocketRef(n.id, old) ? SocketRef(n.id, new) : from) })
                }
            }
        }
        rewrite(&out.root)
        for k in out.definitions.keys { rewrite(&out.definitions[k]!.graph) }
        return out
    }

    /// Removes the socket and every wire that used it (spec §4.5, §20.6).
    public static func removeSocket(_ id: GroupID, kind: SocketKind, name: String, in doc: ShaderDocument) -> ShaderDocument? {
        guard var def = doc.definitions[id], let gin = def.inputNode, let gout = def.outputNode else { return nil }
        switch kind {
        case .input:
            guard def.inputs.contains(where: { $0.name == name }) else { return nil }
            def.inputs.removeAll { $0.name == name }
            def.graph.inputs = def.graph.inputs.filter { $0.value != SocketRef(gin, name) }
        case .output:
            guard def.outputs.contains(where: { $0.name == name }) else { return nil }
            def.outputs.removeAll { $0.name == name }
            def.graph.inputs[SocketRef(gout, name)] = nil
        }
        var out = doc
        out.definitions[id] = def
        func prune(_ g: inout Graph) {
            for n in g.nodes.values where n.kind == .group(id) {
                switch kind {
                case .input: g.inputs[SocketRef(n.id, name)] = nil; g.nodes[n.id]!.params[name] = nil
                case .output: g.inputs = g.inputs.filter { $0.value != SocketRef(n.id, name) }
                }
            }
        }
        prune(&out.root)
        for k in out.definitions.keys { prune(&out.definitions[k]!.graph) }
        return out
    }

    public static func deleteDefinition(_ id: GroupID, in doc: ShaderDocument) -> ShaderDocument? {
        guard doc.definitions[id] != nil, !isUsed(id, in: doc) else { return nil }
        var out = doc; out.definitions[id] = nil; return out
    }

    static func zero(_ t: SocketType) -> ParamValue {
        switch t {
        case .float: .float(0)
        case .float2: .float2(.zero)
        case .float3: .float3(.zero)
        case .float4, .color: .float4(.init(0, 0, 0, 1))
        case .int: .int(0)
        case .bool: .bool(false)
        case .texture: .float(0)
        }
    }
}
