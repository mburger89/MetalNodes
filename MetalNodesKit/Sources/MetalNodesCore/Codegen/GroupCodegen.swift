import Foundation

/// One MSL function per definition (spec §20.4).
public struct GroupFunction: Sendable {
    public let id: GroupID
    public let name: String
    public let structName: String
    public let inputs: [SocketDecl]
    public let outputs: [SocketDecl]
    /// Every uniform slot the body reads, own and propagated, in first-use order. These are the
    /// function's trailing parameters and become requests of whoever calls it.
    public let uniformParams: [(path: ParamPath, type: SocketType)]
    public let requiredStdlib: [String]
    public let source: String
    /// Line owners for the function's body statements, parallel to the body lines in `source`
    /// (the signature and the struct lines have no owner).
    public let lineOwners: [NodeID?]
    /// The viewed value's type when this is a view variant (spec §20.5); `nil` for a normal function.
    /// A variant's only output is `value` of this type.
    public let viewedType: SocketType?

    init(id: GroupID, name: String, structName: String, inputs: [SocketDecl], outputs: [SocketDecl],
         uniformParams: [(path: ParamPath, type: SocketType)], requiredStdlib: [String], source: String,
         lineOwners: [NodeID?], viewedType: SocketType? = nil) {
        self.id = id; self.name = name; self.structName = structName
        self.inputs = inputs; self.outputs = outputs; self.uniformParams = uniformParams
        self.requiredStdlib = requiredStdlib; self.source = source
        self.lineOwners = lineOwners; self.viewedType = viewedType
    }
}

public enum GroupCodegen {
    public static func hex8(_ id: GroupID) -> String { String(id.raw.uuidString.prefix(8)).lowercased() }
    public static func hex8(_ id: NodeID) -> String { String(id.raw.uuidString.prefix(8)).lowercased() }

    public static func functionName(_ def: GroupDefinition) -> String {
        "mn_g_\(StitchableCodegen.sanitizedName(def.name))_\(hex8(def.id))"
    }

    public static func structName(_ id: GroupID) -> String { "G_\(hex8(id))_Out" }

    /// A view variant's result struct: one `value` field (spec §20.5).
    public static func viewStructName(_ id: GroupID) -> String { "G_\(hex8(id))_View" }

    /// `u_<8 hex of the node>_<param>` — stable, target-agnostic, unique per slot.
    public static func parameterName(for path: ParamPath) -> String {
        let node = path.instancePath.first.map(hex8) ?? "0"
        return "u_\(node)_\(StitchableCodegen.sanitizedName(path.param))"
    }

    /// What a view variant terminates at (spec §20.5): the viewed socket inside the definition, plus
    /// the variant to call at that socket's node when the socket is a dived-through instance's `value`.
    struct ViewOutput {
        let socket: SocketRef
        let innerVariant: GroupFunction?
    }

    /// Emits `def`'s function. `functions` must already hold every definition `def` instantiates.
    /// With `view`, emits the definition's **view variant** instead: named `…_view`, its single
    /// output `value` is the viewed socket and its body is emitted from that socket's node.
    static func function(for def: GroupDefinition, document doc: ShaderDocument, registry: NodeRegistry,
                         functions: [GroupID: GroupFunction], view: ViewOutput? = nil) throws(GenerationError) -> GroupFunction {
        let path = GraphPath.definition(def.id)
        let terminal: NodeID
        if let view {
            terminal = view.socket.node
        } else {
            guard let outNode = def.outputNode else { throw .invalid([Diagnostic(.error, "Definition “\(def.name)” has no Group Output")]) }
            terminal = outNode
        }
        let order = TopoSort.order(def.graph, from: terminal)
        let (resolved, diags) = TypeResolver.resolve(def.graph, path: path, document: doc, registry: registry, order: order)
        if !diags.isEmpty { throw .invalid(diags) }
        let emitted = Emitter.emit(order: order, graph: def.graph, path: path, document: doc, registry: registry,
                                   resolved: resolved, env: .groupFunction, reserved: [], functions: functions,
                                   viewInstance: view.flatMap { v in v.innerVariant.map { (id: v.socket.node, function: $0) } })

        // A view variant returns one field, `value`; a normal function one per declared output.
        var viewed: (type: SocketType, variable: String)?
        if let view {
            let type = view.innerVariant?.viewedType ?? resolved[view.socket.node]?.outputTypes[view.socket.socket]
            guard let type, let variable = emitted.outputVars[view.socket] else {
                throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: view.socket.node, socket: view.socket.socket)])
            }
            viewed = (type, variable)
        }
        let fnName = functionName(def) + (viewed == nil ? "" : "_view")
        let outStruct = viewed == nil ? structName(def.id) : viewStructName(def.id)
        let outputs = viewed.map { [SocketDecl(name: "value", type: .concrete($0.type))] } ?? def.outputs

        var b = SourceBuilder()
        b.add("struct \(outStruct) {")
        for o in outputs { b.add("    \(concrete(o.type).mslName) \(o.name);") }
        b.add("};\n")
        var params = ["float2 uv", "float time", "float2 size", "float2 mouse"]
        params += def.inputs.map { "\(concrete($0.type).mslName) in_\($0.name)" }
        params += emitted.uniformRequests.map { "\($0.type.mslName) \(parameterName(for: $0.path))" }
        b.add("\(outStruct) \(fnName)(\(params.joined(separator: ", "))) {")
        for (i, line) in emitted.bodyLines.enumerated() { b.add("    " + line, owner: emitted.lineOwners[i]) }
        b.add("    \(outStruct) out;")
        if let viewed {
            b.add("    out.value = \(viewed.variable);")
        } else {
            let exprs = emitted.inputExpressions[terminal] ?? [:]
            for o in def.outputs { b.add("    out.\(o.name) = \(exprs[o.name] ?? zeroLiteral(concrete(o.type)));") }
        }
        b.add("    return out;")
        b.add("}")
        return GroupFunction(id: def.id, name: fnName, structName: outStruct, inputs: def.inputs, outputs: outputs,
                             uniformParams: emitted.uniformRequests, requiredStdlib: emitted.requiredStdlib,
                             source: b.text, lineOwners: emitted.lineOwners, viewedType: viewed?.type)
    }

    /// Definitions carry no generics (spec §20.2), so an unresolved socket type is a `float`.
    static func concrete(_ t: TypeRef) -> SocketType { if case .concrete(let c) = t { return c } else { return .float } }

    static func zeroLiteral(_ t: SocketType) -> String {
        switch t {
        case .float: "0.0"
        case .float2: "float2(0.0)"
        case .float3: "float3(0.0)"
        case .float4, .color: "float4(0.0, 0.0, 0.0, 1.0)"
        case .int: "0"
        case .bool: "false"
        case .texture: "0.0"
        }
    }
}
