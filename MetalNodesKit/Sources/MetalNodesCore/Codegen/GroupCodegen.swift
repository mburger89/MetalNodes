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
}

public enum GroupCodegen {
    public static func hex8(_ id: GroupID) -> String { String(id.raw.uuidString.prefix(8)).lowercased() }
    public static func hex8(_ id: NodeID) -> String { String(id.raw.uuidString.prefix(8)).lowercased() }

    public static func functionName(_ def: GroupDefinition) -> String {
        "mn_g_\(StitchableCodegen.sanitizedName(def.name))_\(hex8(def.id))"
    }

    public static func structName(_ id: GroupID) -> String { "G_\(hex8(id))_Out" }

    /// `u_<8 hex of the node>_<param>` — stable, target-agnostic, unique per slot.
    public static func parameterName(for path: ParamPath) -> String {
        let node = path.instancePath.first.map(hex8) ?? "0"
        return "u_\(node)_\(StitchableCodegen.sanitizedName(path.param))"
    }

    /// Emits `def`'s function. `functions` must already hold every definition `def` instantiates.
    static func function(for def: GroupDefinition, document doc: ShaderDocument, registry: NodeRegistry,
                         functions: [GroupID: GroupFunction]) throws(GenerationError) -> GroupFunction {
        let path = GraphPath.definition(def.id)
        guard let outNode = def.outputNode else { throw .invalid([Diagnostic(.error, "Definition “\(def.name)” has no Group Output")]) }
        let order = TopoSort.order(def.graph, from: outNode)
        let (resolved, diags) = TypeResolver.resolve(def.graph, path: path, document: doc, registry: registry, order: order)
        if !diags.isEmpty { throw .invalid(diags) }
        let emitted = Emitter.emit(order: order, graph: def.graph, path: path, document: doc, registry: registry,
                                   resolved: resolved, env: .groupFunction, reserved: [], functions: functions)

        let name = functionName(def), structName = structName(def.id)
        var b = SourceBuilder()
        b.add("struct \(structName) {")
        for o in def.outputs { b.add("    \(concrete(o.type).mslName) \(o.name);") }
        b.add("};\n")
        var params = ["float2 uv", "float time", "float2 size", "float2 mouse"]
        params += def.inputs.map { "\(concrete($0.type).mslName) in_\($0.name)" }
        params += emitted.uniformRequests.map { "\($0.type.mslName) \(parameterName(for: $0.path))" }
        b.add("\(structName) \(name)(\(params.joined(separator: ", "))) {")
        for (i, line) in emitted.bodyLines.enumerated() { b.add("    " + line, owner: emitted.lineOwners[i]) }
        b.add("    \(structName) out;")
        let exprs = emitted.inputExpressions[outNode] ?? [:]
        for o in def.outputs { b.add("    out.\(o.name) = \(exprs[o.name] ?? zeroLiteral(concrete(o.type)));") }
        b.add("    return out;")
        b.add("}")
        return GroupFunction(id: def.id, name: name, structName: structName, inputs: def.inputs, outputs: def.outputs,
                             uniformParams: emitted.uniformRequests, requiredStdlib: emitted.requiredStdlib,
                             source: b.text, lineOwners: emitted.lineOwners)
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
