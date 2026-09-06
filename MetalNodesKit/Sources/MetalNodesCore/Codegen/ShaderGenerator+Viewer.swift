import Foundation

/// Viewing a node that lives inside a definition (spec §20.5). Every definition on the way to it
/// is emitted a second time as a **view variant**: one output, `value`, carrying the viewed socket.
extension ShaderGenerator {
    /// `path` is the editing stack — the instances dived through, outermost first. `anchor` is the
    /// definition opened from the palette, when there is one; the path is then anchored inside it
    /// rather than in the root graph.
    ///
    /// With no anchor the outermost variant is called at the dived-through instance's place in the
    /// root program. With one there is no instance to call it at, so a synthetic program calls it
    /// with the definition's declared defaults (spec §9.3: "opened from the palette with no
    /// instance, use the sockets' declared defaults").
    static func viewerInsideDefinition(_ doc: ShaderDocument, viewer v: SocketRef, path: [NodeID], anchor: GroupID?,
                                       registry: NodeRegistry, functions: [GroupID: GroupFunction],
                                       groupFunctions: [GroupFunction]) throws(GenerationError) -> GeneratedShader {
        let hosts = try hostDefinitions(doc, path: path, anchor: anchor)
        guard let innermost = hosts.last, doc.node(v.node)?.path == .definition(innermost.id) else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        // Inner-most first, so each is built before the variant that calls it. `hosts[k]` contains
        // the next instance on the path; the innermost contains the viewed node itself.
        let offset = anchor == nil ? 1 : 0
        var variants: [GroupFunction] = []
        for k in hosts.indices.reversed() {
            let socket = k + offset < path.count ? SocketRef(path[k + offset], "value") : v
            let view = GroupCodegen.ViewOutput(socket: socket, innerVariant: variants.last)
            variants.append(try GroupCodegen.function(for: hosts[k], document: doc, registry: registry,
                                                      functions: functions, view: view))
        }
        guard let outer = variants.last, let type = outer.viewedType else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        if anchor == nil {
            return try rootProgram(doc, viewer: v, path: path, outer: outer, type: type, registry: registry,
                                   functions: functions, variants: variants, groupFunctions: groupFunctions)
        }
        return try syntheticProgram(viewer: v, path: path, outer: outer, type: type,
                                    variants: variants, groupFunctions: groupFunctions)
    }

    /// The root program, terminating at the dived-through instance instead of the Fragment Output.
    private static func rootProgram(_ doc: ShaderDocument, viewer v: SocketRef, path: [NodeID], outer: GroupFunction,
                                    type: SocketType, registry: NodeRegistry, functions: [GroupID: GroupFunction],
                                    variants: [GroupFunction], groupFunctions: [GroupFunction])
        throws(GenerationError) -> GeneratedShader {
        let order = TopoSort.order(doc.root, from: path[0])
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, path: .root, document: doc, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(typeDiags) }
        let emitted = Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry,
                                   resolved: resolved, env: .fragment, reserved: UniformLayoutBuilder.viewerReserved,
                                   functions: functions, viewInstance: (path[0], outer))

        guard let variable = emitted.outputVars[SocketRef(path[0], "value")],
              let wrap = ViewerWrap.statement(variable: variable, type: type) else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        var body = zip(emitted.bodyLines, emitted.lineOwners).map { (line: $0, owner: $1) }
        body.append((wrap, v.node))

        let all = groupFunctions + variants
        let b = fragmentProgram(layout: emitted.layout, stdlib: emitted.requiredStdlib + all.flatMap(\.requiredStdlib),
                                functions: all.map(\.source), body: body, textures: emitted.textureRequests)
        return GeneratedShader(source: b.text, layout: emitted.layout, lineMap: b.map,
                               resolved: merged(resolved, groupFunctions + variants),
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: v, viewerPath: path,
                               textures: emitted.textureRequests)
    }

    /// No instance supplies the outermost variant's exposed inputs, so the synthetic program passes
    /// the sockets' declared defaults as literals. The definitions' own slots stay uniforms, so
    /// editing a value inside them still needs no recompile.
    private static func syntheticProgram(viewer v: SocketRef, path: [NodeID], outer: GroupFunction, type: SocketType,
                                         variants: [GroupFunction], groupFunctions: [GroupFunction])
        throws(GenerationError) -> GeneratedShader {
        let layout = UniformLayoutBuilder.build(outer.uniformParams, reserved: UniformLayoutBuilder.viewerReserved)
        guard let wrap = ViewerWrap.statement(variable: "v0", type: type) else {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        // The variant already deduplicated its slots by asset; this program only has to number them.
        let textures = outer.textureParams.enumerated().map { TextureSlot(index: $0.offset, asset: $0.element.asset) }
        var args = ["in.uv", "u.time", "u.resolution", "u.mouse"]
        args += outer.inputs.map(defaultArgument)
        args += outer.uniformParams.map { EmitEnvironment.fragment.uniform(layout.field(for: $0.path)!) }
        args += textures.map(\.fragmentName)
        let body: [(line: String, owner: NodeID?)] = [
            ("\(outer.structName) r0 = \(outer.name)(\(args.joined(separator: ", ")));", v.node),
            ("\(type.mslName) v0 = r0.value;", v.node),
            (wrap, v.node),
        ]
        let all = groupFunctions + variants
        let b = fragmentProgram(layout: layout, stdlib: all.flatMap(\.requiredStdlib),
                                functions: all.map(\.source), body: body, textures: textures)
        return GeneratedShader(source: b.text, layout: layout, lineMap: b.map,
                               resolved: merged([:], groupFunctions + variants),
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: v, viewerPath: path,
                               textures: textures)
    }

    /// The graphs the viewer sits under, outermost first: the palette-opened definition, when there
    /// is one, then the definition of each dived-through instance. Each id must still be a group
    /// instance inside the previous graph, or the instance the viewer hung off is gone (spec §20.5).
    private static func hostDefinitions(_ doc: ShaderDocument, path: [NodeID], anchor: GroupID?)
        throws(GenerationError) -> [GroupDefinition] {
        let gone = GenerationError.invalid([Diagnostic(.error, "The viewed instance no longer exists")])
        var hosts: [GroupDefinition] = []
        var graph = GraphPath.root
        if let anchor {
            guard let def = doc.definitions[anchor] else { throw gone }
            hosts.append(def)
            graph = .definition(anchor)
        }
        for id in path {
            guard let found = doc.node(id), found.path == graph, case .group(let gid) = found.node.kind,
                  let def = doc.definitions[gid] else { throw gone }
            hosts.append(def)
            graph = .definition(gid)
        }
        return hosts
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
