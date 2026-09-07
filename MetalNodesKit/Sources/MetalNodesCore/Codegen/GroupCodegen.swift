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
    /// Every texture slot the body samples, own and propagated, deduplicated by asset in first-use
    /// order. These follow the uniform parameters and become texture requests of whoever calls it.
    /// The indices are the definition's own numbering; only the assets matter to a caller, which
    /// passes its own slot for each (spec §21.2).
    public let textureParams: [TextureSlot]
    public let requiredStdlib: [String]
    public let source: String
    /// Which node of the definition's graph owns each line of `source`, numbered from 1 within
    /// `source` itself. Whoever splices the function into a program shifts these into its own
    /// numbering, so an error inside the body outlines the node that produced it (spec §9.4).
    /// The result struct, the signature and the epilogue have no owner.
    public let lineMap: LineMap
    /// The viewed value's type when this is a view variant (spec §20.5); `nil` for a normal function.
    /// A variant's only output is `value` of this type.
    public let viewedType: SocketType?
    /// Every node of the definition's graph, typed. `GeneratedShader.resolved` merges these in, so
    /// the editor knows a socket's real type while dived into a definition (ruling R20).
    public let resolved: [NodeID: ResolvedNode]
    /// True for the `…_layer` variant emitted for the Layer Effect export (spec §22.7). Its
    /// `textureParams` still lists what the body samples — that is how a caller knows to call it —
    /// but its signature takes `SwiftUI::Layer layer, float2 position` instead of those textures.
    public let isLayerVariant: Bool

    init(id: GroupID, name: String, structName: String, inputs: [SocketDecl], outputs: [SocketDecl],
         uniformParams: [(path: ParamPath, type: SocketType)], textureParams: [TextureSlot] = [],
         requiredStdlib: [String], source: String,
         lineMap: LineMap, viewedType: SocketType? = nil, resolved: [NodeID: ResolvedNode] = [:],
         isLayerVariant: Bool = false) {
        self.id = id; self.name = name; self.structName = structName
        self.inputs = inputs; self.outputs = outputs; self.uniformParams = uniformParams
        self.textureParams = textureParams
        self.requiredStdlib = requiredStdlib; self.source = source
        self.lineMap = lineMap; self.viewedType = viewedType; self.resolved = resolved
        self.isLayerVariant = isLayerVariant
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
    /// With `layer`, emits the definition's **layer variant**: named `…_layer`, it takes
    /// `SwiftUI::Layer layer, float2 position` in place of its texture parameters and its samples
    /// read the layer (spec §22.7). `layerFunctions` must already hold the layer variant of every
    /// sampling definition `def` instantiates, so nested calls resolve to variants too.
    static func function(for def: GroupDefinition, document doc: ShaderDocument, registry: NodeRegistry,
                         functions: [GroupID: GroupFunction], view: ViewOutput? = nil,
                         layer: Bool = false, layerFunctions: [GroupID: GroupFunction] = [:]) throws(GenerationError) -> GroupFunction {
        switch def.body {
        case .graph(let graph):
            let path = GraphPath.definition(def.id)
            let terminal: NodeID
            if let view {
                terminal = view.socket.node
            } else {
                guard let outNode = def.outputNode else { throw .invalid([Diagnostic(.error, "Definition “\(def.name)” has no Group Output")]) }
                terminal = outNode
            }
            let order = TopoSort.order(graph, from: terminal)
            let (resolved, diags) = TypeResolver.resolve(graph, path: path, document: doc, registry: registry, order: order)
            if !diags.isEmpty { throw .invalid(diags) }
            let emitted = Emitter.emit(order: order, graph: graph, path: path, document: doc, registry: registry,
                                       resolved: resolved, env: layer ? .groupFunctionLayer : .groupFunction,
                                       reserved: [], functions: functions,
                                       viewInstance: view.flatMap { v in v.innerVariant.map { (id: v.socket.node, function: $0) } },
                                       layerFunctions: layerFunctions)

            // A view variant returns one field, `value`; a normal function one per declared output.
            var viewed: (type: SocketType, variable: String)?
            if let view {
                let type = view.innerVariant?.viewedType ?? resolved[view.socket.node]?.outputTypes[view.socket.socket]
                guard let type, let variable = emitted.outputVars[view.socket] else {
                    throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: view.socket.node, socket: view.socket.socket)])
                }
                viewed = (type, variable)
            }
            let fnName = functionName(def) + (viewed == nil ? "" : "_view") + (layer ? "_layer" : "")
            let outStruct = viewed == nil ? structName(def.id) : viewStructName(def.id)
            let outputs = viewed.map { [SocketDecl(name: "value", type: .concrete($0.type))] } ?? def.outputs

            var b = SourceBuilder()
            writeResultStruct(&b, outStruct: outStruct, outputs: outputs)
            var params = systemParams(def)
            params += emitted.uniformRequests.map { "\($0.type.mslName) \(parameterName(for: $0.path))" }
            params += layer ? ["SwiftUI::Layer layer", "float2 position"]
                            : emitted.textureRequests.map { "texture2d<float> \($0.parameterName)" }
            b.add("\(outStruct) \(fnName)(\(params.joined(separator: ", "))) {")
            for (i, line) in emitted.bodyLines.enumerated() { b.add("    " + line, owner: emitted.lineOwners[i]) }
            if let viewed {
                writeEpilogue(&b, outStruct: outStruct, outputs: outputs, resultVar: "out") { _ in viewed.variable }
            } else {
                let exprs = emitted.inputExpressions[terminal] ?? [:]
                writeEpilogue(&b, outStruct: outStruct, outputs: outputs, resultVar: "out") { exprs[$0.name] ?? zeroLiteral(concrete($0.type)) }
            }
            return GroupFunction(id: def.id, name: fnName, structName: outStruct, inputs: def.inputs, outputs: outputs,
                                 uniformParams: emitted.uniformRequests, textureParams: emitted.textureRequests,
                                 requiredStdlib: emitted.requiredStdlib,
                                 source: b.text, lineMap: b.map, viewedType: viewed?.type, resolved: resolved,
                                 isLayerVariant: layer)

        case .msl(let text):
            // A `.msl` definition has no nodes, so nothing requests a uniform or texture slot: its
            // function is built with empty uniform/texture parameter lists and no required stdlib.
            // `view` is a `.graph`-only concept — viewing a socket means diving into a node inside
            // the definition, and a `.msl` body has no nodes to dive into, so `view` is unused
            // here. Unreachable today: `viewerInsideDefinition` only ever builds a `view` for a
            // definition that actually contains the viewed node's path
            // (`ShaderGenerator+Viewer.swift`), which a `.msl` definition, having no graph, never
            // does. Harmless if it ever were reached anyway — this returns a normal function with
            // `viewedType: nil`, and the caller already refuses that (`guard let type =
            // outer.viewedType else { throw ... }` in `viewerInsideDefinition`), so the failure
            // still surfaces as a diagnostic rather than a wrong render.
            let fnName = functionName(def) + (layer ? "_layer" : "")
            let outStruct = structName(def.id)
            let outputs = def.outputs

            var b = SourceBuilder()
            writeResultStruct(&b, outStruct: outStruct, outputs: outputs)
            var params = systemParams(def)
            params += layer ? ["SwiftUI::Layer layer", "float2 position"] : []
            b.add("\(outStruct) \(fnName)(\(params.joined(separator: ", "))) {")
            // Declared zero-initialised before the user's text lands, so a body that forgets to
            // assign an output still compiles and renders black rather than failing on scaffolding
            // the user cannot see. Inputs are already in scope as `in_<name>`; the user assigns the
            // outputs by their declared names, which the shared epilogue below packs into the result
            // struct (spec §24.3).
            for decl in outputs {
                b.add("    \(concrete(decl.type).mslName) \(decl.name) = \(zeroLiteral(concrete(decl.type)));")
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                b.add("    " + line)
            }
            // The result-struct local cannot be named `out` unconditionally: the user's own text
            // may already declare a local of that name (an output literally called `out` is the
            // idiomatic case — spec §24.3's own examples use it), which would collide with a
            // fixed `out` inside the same scope. `outStruct` already carries the definition's
            // unique hex id, so starting from it keeps this name out of the user's reach in the
            // ordinary case — but an output can still be named exactly `<outStruct>_result`, so
            // `uniqueResultVar` below lengthens it until it provably isn't any declared output's
            // name, rather than merely being unlikely to collide with one. (Not derived from
            // `fnName`: that string is a prefix of it, and a test counts `fnName`'s occurrences as
            // a proxy for call-site sharing — deriving from it would inflate that count.) An input
            // can never collide here: it is always spelled `in_<name>` in the body, never bare.
            let resultVar = uniqueResultVar(base: "\(outStruct)_result", outputs: outputs)
            writeEpilogue(&b, outStruct: outStruct, outputs: outputs, resultVar: resultVar) { $0.name }
            return GroupFunction(id: def.id, name: fnName, structName: outStruct, inputs: def.inputs, outputs: outputs,
                                 uniformParams: [], textureParams: [], requiredStdlib: [],
                                 source: b.text, lineMap: b.map, viewedType: nil, resolved: [:],
                                 isLayerVariant: layer)
        }
    }

    /// The function's four leading system parameters, name and MSL type. The single source of
    /// truth for both their declaration here and the reserved-name set `GroupOperations` refuses
    /// on a `.msl` definition's own socket names — the two must never disagree, since a fifth
    /// parameter added here without updating that reservation would emit a definition that
    /// compiles right up until a user names an output after it (spec §24.3).
    static let systemParamNames: [(name: String, mslType: String)] = [
        ("uv", "float2"), ("time", "float"), ("size", "float2"), ("mouse", "float2"),
    ]

    /// `float2 uv, float time, float2 size, float2 mouse` plus the definition's declared inputs,
    /// spelled `in_<name>` — shared by both body kinds so a `.msl` function is indistinguishable
    /// to its caller from a `.graph` one (spec §24.3).
    private static func systemParams(_ def: GroupDefinition) -> [String] {
        var params = systemParamNames.map { "\($0.mslType) \($0.name)" }
        params += def.inputs.map { "\(concrete($0.type).mslName) in_\($0.name)" }
        return params
    }

    /// `base`, lengthened until it cannot equal any declared output's name — total, not merely
    /// unlikely: each iteration strictly lengthens the candidate, and `outputs` is finite, so this
    /// always terminates with a name no output can be spelled as.
    private static func uniqueResultVar(base: String, outputs: [SocketDecl]) -> String {
        let names = Set(outputs.map(\.name))
        var candidate = base
        while names.contains(candidate) { candidate += "_" }
        return candidate
    }

    private static func writeResultStruct(_ b: inout SourceBuilder, outStruct: String, outputs: [SocketDecl]) {
        b.add("struct \(outStruct) {")
        for o in outputs { b.add("    \(concrete(o.type).mslName) \(o.name);") }
        b.add("};\n")
    }

    /// Packs each output into the result struct and closes the function. Shared by both body
    /// kinds — the epilogue that makes a `.msl` function indistinguishable to its caller must not
    /// be duplicated (spec §24.3). `resultVar` names the local struct instance; callers pick one
    /// that cannot collide with an identifier already in scope.
    private static func writeEpilogue(_ b: inout SourceBuilder, outStruct: String, outputs: [SocketDecl],
                                       resultVar: String, expression: (SocketDecl) -> String) {
        b.add("    \(outStruct) \(resultVar);")
        for o in outputs { b.add("    \(resultVar).\(o.name) = \(expression(o));") }
        b.add("    return \(resultVar);")
        b.add("}")
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
