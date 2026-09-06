import Foundation

/// Turns resolved nodes into SSA statements. Internal; `ShaderGenerator` is the API.
enum Emitter {
    struct Output {
        var bodyLines: [String] = []            // statements inside shaderMain, unindented
        var lineOwners: [NodeID?] = []          // parallel to bodyLines
        var layout: UniformLayout
        var requiredStdlib: [String] = []
        var outputVars: [SocketRef: String] = [:]
        var inputExpressions: [NodeID: [String: String]] = [:]
        /// Every slot this graph needs, deduplicated in first-use order: its own unwired inputs
        /// and value params plus the ones its group calls pass through (spec §20.4). The layout
        /// is built from exactly this list.
        var uniformRequests: [(path: ParamPath, type: SocketType)] = []
        /// Every texture slot this graph needs, deduplicated by asset in first-use order: the ones
        /// its own Texture Samples read plus the ones its group calls pass through (spec §21.2).
        var textureRequests: [TextureSlot] = []
    }

    /// Which `{in.x}` / `{param.x}` names a body references (rule 4), and whether it samples a texture.
    static func referencedNames(in body: NodeBody, chosen: String?)
        -> (inputs: Set<String>, params: Set<String>, usesTexture: Bool) {
        let text: String
        switch body {
        case .template(let t): text = t
        case .variants(_, let table): text = chosen.flatMap { table[$0] } ?? ""
        case .custom: return (inputs: [], params: [], usesTexture: false)
        }
        var ins = Set<String>(), ps = Set<String>(), tex = false
        for m in text.matches(of: NodeRegistry.placeholderPattern) {
            switch m.1 {
            case "in": ins.insert(String(m.2))
            case "param": ps.insert(String(m.2))
            case "tex": tex = true
            default: break
            }
        }
        return (ins, ps, tex)
    }

    static func chosenVariant(_ def: NodeDef, _ inst: NodeInstance) -> String? {
        guard case .variants(let param, _) = def.body else { return nil }
        if case .enumCase(let c)? = inst.params[param] { return c }
        if case .enumCase(let c) = def.param(named: param)!.defaultValue { return c }
        return nil
    }

    static func emit(order: [NodeID], graph: Graph, path: GraphPath = .root, document doc: ShaderDocument? = nil,
                     registry: NodeRegistry, resolved: [NodeID: ResolvedNode],
                     env: EmitEnvironment = .fragment,
                     reserved: [UniformLayoutBuilder.Reserved] = UniformLayoutBuilder.standardReserved,
                     functions: [GroupID: GroupFunction] = [:],
                     viewInstance: (id: NodeID, function: GroupFunction)? = nil) -> Output {
        let doc = doc ?? { var d = ShaderDocument(); d.root = graph; return d }()
        func shape(_ inst: NodeInstance) -> NodeShape? { doc.shape(of: inst, in: path, registry: registry) }
        /// A pseudo-node's shape ends in the `+` socket, which is a gesture target rather than
        /// anything to emit — the definition's signature comes from its declared sockets (spec §20.6).
        func declared(_ decls: [SocketDecl]) -> [SocketDecl] { decls.filter { !NodeShape.isPlus($0) } }
        /// The dived-through instance calls its definition's view variant; every other instance of
        /// the same definition keeps the normal function (spec §20.5).
        func function(for gid: GroupID, at id: NodeID) -> GroupFunction? {
            viewInstance.flatMap { $0.id == id ? $0.function : nil } ?? functions[gid]
        }

        // Pass 1: collect uniform requests in a deterministic, deduplicated order.
        var requests: [(path: ParamPath, type: SocketType)] = []
        var requested = Set<ParamPath>()
        func request(_ p: ParamPath, _ type: SocketType) {
            guard type.isUniformable, requested.insert(p).inserted else { return }
            requests.append((p, type))
        }
        /// An unwired input with a `.value` default is a slot (spec §9.2).
        func requestUnwiredInputs(_ id: NodeID, _ decls: [SocketDecl], _ r: ResolvedNode) {
            for decl in decls where graph.inputs[SocketRef(id, decl.name)] == nil {
                if case .value = decl.default { request(ParamPath(node: id, param: decl.name), r.inputTypes[decl.name]!) }
            }
        }
        /// One slot per distinct asset, in first-use order; unassigned samples share the `nil` slot.
        var textureSlots: [AssetID?: TextureSlot] = [:]
        var textureOrder: [TextureSlot] = []
        /// The slot each sampling node reads, so pass 2 need not re-scan bodies for `{tex.sample}`.
        var textureSlotOfNode: [NodeID: TextureSlot] = [:]
        @discardableResult func requestTexture(_ asset: AssetID?) -> TextureSlot {
            if let existing = textureSlots[asset] { return existing }
            let slot = TextureSlot(index: textureOrder.count, asset: asset)
            textureSlots[asset] = slot
            textureOrder.append(slot)
            return slot
        }
        /// The asset a Texture Sample instance names; `nil` when unset or set to nothing.
        func asset(of inst: NodeInstance) -> AssetID? {
            if case .asset(let a)? = inst.params["asset"] { return a }
            return nil
        }
        for id in order {
            guard let inst = graph.nodes[id], let r = resolved[id] else { continue }
            switch inst.kind {
            case .builtin(let defID):
                guard let def = registry[defID] else { continue }
                let refs = referencedNames(in: def.body, chosen: chosenVariant(def, inst))
                let custom: Bool = { if case .custom = def.body { return true } else { return false } }()
                requestUnwiredInputs(id, def.inputs.filter { custom || refs.inputs.contains($0.name) }, r)
                for p in def.params where (custom || refs.params.contains(p.name)) {
                    if case .value(let t, _) = p.kind { request(ParamPath(node: id, param: p.name), t) }
                }
                if refs.usesTexture { textureSlotOfNode[id] = requestTexture(asset(of: inst)) }
            case .group(let gid):
                // The instance's own unwired exposed inputs, then everything its function needs.
                if let s = shape(inst) { requestUnwiredInputs(id, s.inputs, r) }
                for p in function(for: gid, at: id)?.uniformParams ?? [] { request(p.path, p.type) }
                for slot in function(for: gid, at: id)?.textureParams ?? [] { requestTexture(slot.asset) }
            case .groupOutput:
                if let s = shape(inst) { requestUnwiredInputs(id, declared(s.inputs), r) }
            case .groupInput:
                break
            }
        }
        var out = Output(layout: UniformLayoutBuilder.build(requests, reserved: reserved))
        out.uniformRequests = requests
        out.textureRequests = textureOrder

        func uniformExpr(_ path: ParamPath) -> String {
            env.uniform(out.layout.field(for: path)!)
        }

        /// Wired → the source variable converted; unwired → the slot, `{sys.uv}`, or a marker.
        func inputExpressions(_ id: NodeID, _ decls: [SocketDecl], _ r: ResolvedNode) -> [String: String] {
            var inputs: [String: String] = [:]
            for decl in decls {
                let dst = r.inputTypes[decl.name]!
                if let src = graph.inputs[SocketRef(id, decl.name)], let v = out.outputVars[src],
                   let srcType = resolved[src.node]?.outputTypes[src.socket] {
                    inputs[decl.name] = ConversionRules.convert(from: srcType, to: dst)!.apply(v)
                } else {
                    switch decl.default {
                    case .uv: inputs[decl.name] = env.sys["uv"] ?? "in.uv"
                    case .value:
                        let path = ParamPath(node: id, param: decl.name)
                        if out.layout.field(for: path) != nil { inputs[decl.name] = uniformExpr(path) }
                    case .required: inputs[decl.name] = "/* unconnected */"
                    }
                }
            }
            return inputs
        }

        // Pass 2: statements.
        var varCounter = 0
        /// One SSA variable per output socket, so downstream conversion works the same for every kind.
        func declareOutputs(_ id: NodeID, _ decls: [SocketDecl], _ r: ResolvedNode) -> [String: String] {
            var outputs: [String: String] = [:]
            for decl in decls {
                let name = "v\(varCounter)"; varCounter += 1
                outputs[decl.name] = name
                out.outputVars[SocketRef(id, decl.name)] = name
                out.bodyLines.append("\(r.outputTypes[decl.name]!.mslName) \(name);")
                out.lineOwners.append(id)
            }
            return outputs
        }
        for id in order {
            guard let inst = graph.nodes[id], let r = resolved[id] else { continue }
            switch inst.kind {
            case .builtin(let defID):
                guard let def = registry[defID] else { continue }
                out.requiredStdlib += def.requires
                let outputs = declareOutputs(id, def.outputs, r)
                let inputs = inputExpressions(id, def.inputs, r)
                out.inputExpressions[id] = inputs
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
                let texture = textureSlotOfNode[id]
                    .map { env.textureSample($0, inputs["uv"] ?? env.sys["uv"] ?? "in.uv") } ?? ""
                let ctx = EmitContext(inputs: inputs, outputs: outputs, params: params, enums: enums,
                                      types: r.generics, sys: env.sys, texture: texture)

                let lines: [String]
                switch def.body {
                case .template(let t): lines = substitute(t, ctx)
                case .variants(let param, let table):
                    // The instance-provided case may be stale/invalid (hand-edited or renamed
                    // since save); never force-unwrap it. Fall back to the def's default case.
                    let defaultCase: String? = { if case .enumCase(let c) = def.param(named: param)!.defaultValue { return c } else { return nil } }()
                    let chosen = enums[param].flatMap { table[$0] != nil ? $0 : nil } ?? defaultCase
                    lines = substitute(chosen.flatMap { table[$0] } ?? "", ctx)
                case .custom(let f): lines = f(ctx)
                }
                for l in lines { out.bodyLines.append(l); out.lineOwners.append(id) }

            case .groupInput:
                // Each exposed input arrives as a function parameter (spec §20.4).
                guard let s = shape(inst) else { continue }
                let outputs = declareOutputs(id, declared(s.outputs), r)
                for decl in declared(s.outputs) {
                    out.bodyLines.append("\(outputs[decl.name]!) = in_\(decl.name);")
                    out.lineOwners.append(id)
                }

            case .groupOutput:
                // No statements: the enclosing function turns these expressions into struct fields.
                guard let s = shape(inst) else { continue }
                let inputs = inputExpressions(id, declared(s.inputs), r)
                out.inputExpressions[id] = inputs

            case .group(let gid):
                guard let s = shape(inst), let fn = function(for: gid, at: id) else { continue }
                let inputs = inputExpressions(id, s.inputs, r)
                out.inputExpressions[id] = inputs
                let result = "r\(varCounter)"; varCounter += 1
                var args = [env.sys["uv"] ?? "in.uv", env.sys["time"] ?? "u.time",
                            env.sys["resolution"] ?? "u.resolution", env.sys["mouse"] ?? "u.mouse"]
                args += fn.inputs.map { inputs[$0.name] ?? GroupCodegen.zeroLiteral(r.inputTypes[$0.name] ?? .float) }
                args += fn.uniformParams.map { uniformExpr($0.path) }
                // The function names its texture parameters by asset; this program spells the same
                // assets by its own slots (spec §21.2).
                args += fn.textureParams.map { env.textureName(textureSlots[$0.asset]!) }
                out.bodyLines.append("\(fn.structName) \(result) = \(fn.name)(\(args.joined(separator: ", ")));")
                out.lineOwners.append(id)
                if let viewed = fn.viewedType {
                    // A view variant yields one socket, `value`: the viewed node's output (spec §20.5).
                    let name = "v\(varCounter)"; varCounter += 1
                    out.outputVars[SocketRef(id, "value")] = name
                    out.bodyLines.append("\(viewed.mslName) \(name) = \(result).value;")
                    out.lineOwners.append(id)
                    continue
                }
                let outputs = declareOutputs(id, s.outputs, r)
                for decl in s.outputs {
                    out.bodyLines.append("\(outputs[decl.name]!) = \(result).\(decl.name);")
                    out.lineOwners.append(id)
                }
            }
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
            case "sys": return ctx.sys[name] ?? "/* ?sys.\(name) */"
            case "tex": return ctx.texture
            default: return String(m.0)
            }
        }
        return replaced.components(separatedBy: "\n")
    }
}
