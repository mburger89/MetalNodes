import Foundation

/// Viewing a node that lives inside a definition (spec §20.5). Every definition on the way to it
/// is emitted a second time as a **view variant**: one output, `value`, carrying the viewed socket.
extension ShaderGenerator {
    /// Case B — the editing stack: the outermost variant is called at the dived-through instance's
    /// place in the root order, and its value is wrapped for display.
    static func viewerThroughInstances(_ doc: ShaderDocument, viewer v: SocketRef, path: [NodeID], registry: NodeRegistry,
                                       functions: [GroupID: GroupFunction], groupFunctions: [GroupFunction])
        throws(GenerationError) -> GeneratedShader {
        let chain = try definitionChain(doc, path: path)
        guard let innermost = chain.last, doc.node(v.node)?.path == .definition(innermost.id) else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        // Inner-most first: each outer variant terminates at the next instance's `value`, so it
        // calls that instance's variant rather than its normal function.
        var variants: [GroupFunction] = []
        for i in chain.indices.reversed() {
            let socket = i == chain.count - 1 ? v : SocketRef(path[i + 1], "value")
            let view = GroupCodegen.ViewOutput(socket: socket, innerVariant: variants.last)
            variants.append(try GroupCodegen.function(for: chain[i], document: doc, registry: registry,
                                                      functions: functions, view: view))
        }
        guard let outer = variants.last, let type = outer.viewedType else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }

        let order = TopoSort.order(doc.root, from: path[0])
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, path: .root, document: doc, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(typeDiags) }
        let emitted = Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry,
                                   resolved: resolved, env: .fragment, reserved: UniformLayoutBuilder.viewerReserved,
                                   functions: functions, viewInstance: (path[0], outer))

        var body = zip(emitted.bodyLines, emitted.lineOwners).map { (line: $0, owner: $1) }
        if let variable = emitted.outputVars[SocketRef(path[0], "value")],
           let wrap = ViewerWrap.statement(variable: variable, type: type) {
            body.append((wrap, v.node))
        }
        let all = groupFunctions + variants
        let b = fragmentProgram(layout: emitted.layout, stdlib: emitted.requiredStdlib + all.flatMap(\.requiredStdlib),
                                functions: all.map(\.source), body: body)
        return GeneratedShader(source: b.text, layout: emitted.layout, lineMap: b.map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: v, viewerPath: path)
    }

    /// Case C — opened from the palette, so no instance supplies the exposed inputs: the synthetic
    /// program calls the variant with the sockets' declared defaults as literals. The definition's
    /// own slots stay uniforms, so editing a value inside it still needs no recompile.
    static func viewerFromDefinition(_ doc: ShaderDocument, viewer v: SocketRef, definition gid: GroupID, registry: NodeRegistry,
                                     functions: [GroupID: GroupFunction], groupFunctions: [GroupFunction])
        throws(GenerationError) -> GeneratedShader {
        guard let def = doc.definitions[gid] else {
            throw .invalid([Diagnostic(.error, "The viewed instance no longer exists")])
        }
        guard doc.node(v.node)?.path == .definition(gid) else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        let variant = try GroupCodegen.function(for: def, document: doc, registry: registry, functions: functions,
                                                view: GroupCodegen.ViewOutput(socket: v, innerVariant: nil))
        guard let type = variant.viewedType else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        let layout = UniformLayoutBuilder.build(variant.uniformParams, reserved: UniformLayoutBuilder.viewerReserved)

        var args = ["in.uv", "u.time", "u.resolution", "u.mouse"]
        args += def.inputs.map(defaultArgument)
        args += variant.uniformParams.map { EmitEnvironment.fragment.uniform(layout.field(for: $0.path)!) }
        var body: [(line: String, owner: NodeID?)] = [
            ("\(variant.structName) r0 = \(variant.name)(\(args.joined(separator: ", ")));", v.node),
            ("\(type.mslName) v0 = r0.value;", v.node),
        ]
        if let wrap = ViewerWrap.statement(variable: "v0", type: type) { body.append((wrap, v.node)) }

        let all = groupFunctions + [variant]
        let b = fragmentProgram(layout: layout, stdlib: all.flatMap(\.requiredStdlib),
                                functions: all.map(\.source), body: body)
        return GeneratedShader(source: b.text, layout: layout, lineMap: b.map, resolved: [:],
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: v)
    }

    /// Each id must still be a group instance inside the previous one's definition — the first in
    /// the root. Anything else means the instance the viewer hung off is gone (spec §20.5).
    private static func definitionChain(_ doc: ShaderDocument, path: [NodeID]) throws(GenerationError) -> [GroupDefinition] {
        var chain: [GroupDefinition] = []
        var host = GraphPath.root
        for id in path {
            guard let found = doc.node(id), found.path == host, case .group(let gid) = found.node.kind,
                  let def = doc.definitions[gid] else {
                throw .invalid([Diagnostic(.error, "The viewed instance no longer exists")])
            }
            chain.append(def)
            host = .definition(gid)
        }
        return chain
    }

    /// An exposed input with no instance behind it: its declared default, as an MSL literal.
    private static func defaultArgument(for decl: SocketDecl) -> String {
        let type = GroupCodegen.concrete(decl.type)
        switch decl.default {
        case .uv: return "in.uv"
        case .required: return GroupCodegen.zeroLiteral(type)
        case .value(let value):
            guard let from = value.socketType, let conversion = ConversionRules.convert(from: from, to: type) else {
                return GroupCodegen.zeroLiteral(type)
            }
            return conversion.apply(value.mslLiteral)
        }
    }
}
