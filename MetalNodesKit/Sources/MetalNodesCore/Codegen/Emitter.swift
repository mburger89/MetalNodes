import Foundation

/// Turns resolved nodes into SSA statements. Internal; `ShaderGenerator` is the API.
enum Emitter {
    struct Output {
        var bodyLines: [String] = []            // statements inside shaderMain, unindented
        var lineOwners: [NodeID?] = []          // parallel to bodyLines
        var layout: UniformLayout
        var requiredStdlib: [String] = []
    }

    /// Which `{in.x}` / `{param.x}` names a body references (rule 4).
    static func referencedNames(in body: NodeBody, chosen: String?) -> (inputs: Set<String>, params: Set<String>) {
        let text: String
        switch body {
        case .template(let t): text = t
        case .variants(_, let table): text = chosen.flatMap { table[$0] } ?? ""
        case .custom: return (inputs: [], params: [])
        }
        var ins = Set<String>(), ps = Set<String>()
        for m in text.matches(of: NodeRegistry.placeholderPattern) {
            if m.1 == "in" { ins.insert(String(m.2)) } else if m.1 == "param" { ps.insert(String(m.2)) }
        }
        return (ins, ps)
    }

    static func chosenVariant(_ def: NodeDef, _ inst: NodeInstance) -> String? {
        guard case .variants(let param, _) = def.body else { return nil }
        if case .enumCase(let c)? = inst.params[param] { return c }
        if case .enumCase(let c) = def.param(named: param)!.defaultValue { return c }
        return nil
    }

    static func emit(order: [NodeID], graph: Graph, registry: NodeRegistry,
                     resolved: [NodeID: ResolvedNode]) -> Output {
        // Pass 1: collect uniform requests in a deterministic order.
        var requests: [(path: ParamPath, type: SocketType)] = []
        for id in order {
            guard let inst = graph.nodes[id], case .builtin(let defID) = inst.kind,
                  let def = registry[defID], let r = resolved[id] else { continue }
            let refs = referencedNames(in: def.body, chosen: chosenVariant(def, inst))
            let custom: Bool = { if case .custom = def.body { return true } else { return false } }()
            for decl in def.inputs where (custom || refs.inputs.contains(decl.name)) {
                if graph.inputs[SocketRef(id, decl.name)] != nil { continue }
                if case .value = decl.default { requests.append((ParamPath(node: id, param: decl.name), r.inputTypes[decl.name]!)) }
            }
            for p in def.params where (custom || refs.params.contains(p.name)) {
                if case .value(let t, _) = p.kind { requests.append((ParamPath(node: id, param: p.name), t)) }
            }
        }
        var out = Output(layout: UniformLayoutBuilder.build(requests))

        func uniformExpr(_ path: ParamPath) -> String {
            let f = out.layout.field(for: path)!
            return f.type == .bool ? "bool(u.\(f.name))" : "u.\(f.name)"
        }

        // Pass 2: statements.
        var varCounter = 0
        var outputVars: [SocketRef: String] = [:]
        for id in order {
            guard let inst = graph.nodes[id], case .builtin(let defID) = inst.kind,
                  let def = registry[defID], let r = resolved[id] else { continue }
            out.requiredStdlib += def.requires

            // Declare outputs.
            var outputs: [String: String] = [:]
            for decl in def.outputs {
                let name = "v\(varCounter)"; varCounter += 1
                outputs[decl.name] = name
                outputVars[SocketRef(id, decl.name)] = name
                out.bodyLines.append("\(r.outputTypes[decl.name]!.mslName) \(name);")
                out.lineOwners.append(id)
            }

            // Input expressions.
            var inputs: [String: String] = [:]
            for decl in def.inputs {
                let dst = r.inputTypes[decl.name]!
                if let src = graph.inputs[SocketRef(id, decl.name)], let v = outputVars[src],
                   let srcType = resolved[src.node]?.outputTypes[src.socket] {
                    inputs[decl.name] = ConversionRules.convert(from: srcType, to: dst)!.apply(v)
                } else {
                    switch decl.default {
                    case .uv: inputs[decl.name] = "in.uv"
                    case .value:
                        let path = ParamPath(node: id, param: decl.name)
                        if out.layout.field(for: path) != nil { inputs[decl.name] = uniformExpr(path) }
                    case .required: inputs[decl.name] = "/* unconnected */"
                    }
                }
            }
            var params: [String: String] = [:], enums: [String: String] = [:]
            for p in def.params {
                switch p.kind {
                case .value: if out.layout.field(for: ParamPath(node: id, param: p.name)) != nil { params[p.name] = uniformExpr(ParamPath(node: id, param: p.name)) }
                case .enumeration:
                    if case .enumCase(let c)? = inst.params[p.name] { enums[p.name] = c }
                    else if case .enumCase(let c) = p.defaultValue { enums[p.name] = c }
                case .asset: break
                }
            }
            let ctx = EmitContext(inputs: inputs, outputs: outputs, params: params, enums: enums, types: r.generics)

            let lines: [String]
            switch def.body {
            case .template(let t): lines = substitute(t, ctx)
            case .variants(let param, let table): lines = substitute(table[enums[param]!]!, ctx)
            case .custom(let f): lines = f(ctx)
            }
            for l in lines { out.bodyLines.append(l); out.lineOwners.append(id) }
        }
        return out
    }

    static func substitute(_ template: String, _ ctx: EmitContext) -> [String] {
        let replaced = template.replacing(NodeRegistry.placeholderPattern) { m -> String in
            let name = String(m.2)
            switch m.1 {
            case "in": return ctx.inputs[name] ?? "/* ?in.\(name) */"
            case "out": return ctx.outputs[name] ?? "/* ?out.\(name) */"
            case "param": return ctx.params[name] ?? "/* ?param.\(name) */"
            case "type": return ctx.types[name]?.mslName ?? "float"
            default: return String(m.0)
            }
        }
        return replaced.components(separatedBy: "\n")
    }
}
