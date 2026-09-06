import Foundation

public struct GeneratedShader: Sendable, Hashable {
    public let source: String
    public let layout: UniformLayout
    public let lineMap: LineMap
    public let resolved: [NodeID: ResolvedNode]
    public let fragmentFunctionName: String
    public let target: OutputTarget
    /// The node/socket previewed, when this is a viewer program (spec §19.3).
    public let viewer: SocketRef?
    /// The instances dived through to reach the viewed node, outermost first (spec §20.5).
    /// Empty when the viewer is in the root or the definition was opened from the palette.
    public let viewerPath: [NodeID]
    /// The stitchable function's source, when `target` is `.stitchable` (T4). `nil` for a viewer or a fragment program.
    public let exportSource: String?
    /// The exported SwiftUI stitchable function's name. Empty when `exportSource` is `nil`.
    public let functionName: String
    /// The texture bindings this program declares, in slot order (spec §21.2). The renderer binds
    /// slot `i` with `setFragmentTexture(_:index: i)`.
    public let textures: [TextureSlot]

    public init(source: String, layout: UniformLayout, lineMap: LineMap, resolved: [NodeID: ResolvedNode],
                fragmentFunctionName: String, target: OutputTarget, viewer: SocketRef? = nil,
                viewerPath: [NodeID] = [], exportSource: String? = nil, functionName: String = "",
                textures: [TextureSlot] = []) {
        self.source = source
        self.layout = layout
        self.lineMap = lineMap
        self.resolved = resolved
        self.fragmentFunctionName = fragmentFunctionName
        self.target = target
        self.viewer = viewer
        self.viewerPath = viewerPath
        self.exportSource = exportSource
        self.functionName = functionName
        self.textures = textures
    }
}

public enum ShaderGenerator {
    public static let fragmentFunctionName = "shaderMain"

    /// The root's types plus every emitted definition's (ruling R20). Node ids are unique
    /// document-wide, so the maps cannot disagree — a definition emitted both normally and as a
    /// view variant types the same nodes the same way. The editor reads this while dived into a
    /// definition, where a generic socket's real type is otherwise unknowable (spec §20.5).
    static func merged(_ root: [NodeID: ResolvedNode], _ functions: [GroupFunction]) -> [NodeID: ResolvedNode] {
        var out = root
        for f in functions { out.merge(f.resolved) { $1 } }
        return out
    }

    /// `viewerPath` is the editing stack: the instances dived through to reach `viewer`, outermost
    /// first. `viewerDefinition` names the definition when it was opened from the palette with no
    /// instance — its declared defaults stand in for one (spec §20.5).
    public static func generate(_ doc: ShaderDocument, target: OutputTarget = .fragment, viewer: SocketRef? = nil,
                                viewerPath: [NodeID] = [], viewerDefinition: GroupID? = nil,
                                registry: NodeRegistry = .builtin) throws(GenerationError) -> GeneratedShader {
        let structural = GraphValidator.validate(document: doc, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { throw .invalid(structural) }
        if let v = viewer, !GraphValidator.isValidViewer(v, in: doc, registry: registry) {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        let terminal = GraphValidator.terminal(in: doc.root)!

        // One function per reachable definition, inner-most first, so each is already built
        // when the definitions and the program that call it are emitted (spec §20.4). A
        // definition previewed from the palette need not be instantiated anywhere.
        var reachable = GroupDependencies.reachable(from: doc.root, in: doc)
        if viewer != nil, let gid = viewerDefinition, doc.definitions[gid] != nil {
            reachable.insert(gid)
            reachable.formUnion(GroupDependencies.transitive(gid, in: doc))
        }
        let groupOrder = GroupDependencies.innerFirst(reachable, in: doc)
        var functions: [GroupID: GroupFunction] = [:]
        for gid in groupOrder {
            functions[gid] = try GroupCodegen.function(for: doc.definitions[gid]!, document: doc, registry: registry, functions: functions)
        }
        let groupFunctions = groupOrder.compactMap { functions[$0] }

        // A viewer inside a definition runs through view variants of the definitions on the path
        // (spec §20.5); one in the root is the ordinary program terminating early.
        if let v = viewer {
            if !viewerPath.isEmpty || viewerDefinition != nil {
                return try viewerInsideDefinition(doc, viewer: v, path: viewerPath, anchor: viewerDefinition,
                                                  registry: registry, functions: functions, groupFunctions: groupFunctions)
            }
            guard doc.root.nodes[v.node] != nil else {
                throw .invalid([Diagnostic(.error, "The viewed instance no longer exists")])
            }
        }

        let start = viewer?.node ?? terminal
        let order = TopoSort.order(doc.root, from: start)
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, path: .root, document: doc, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(structural + typeDiags) }

        // A viewer is a preview concept: always a fragment program (spec §19.3).
        let effectiveTarget: OutputTarget = viewer == nil ? target : .fragment
        switch effectiveTarget {
        case .fragment:
            return assembleFragment(doc, order: order, terminal: terminal, viewer: viewer, resolved: resolved, registry: registry,
                                    functions: functions, groupFunctions: groupFunctions)
        case .stitchable(let kind):
            return assembleStitchable(doc, kind: kind, order: order, terminal: terminal, resolved: resolved, registry: registry,
                                      functions: functions, groupFunctions: groupFunctions)
        }
    }

    private static func assembleFragment(_ doc: ShaderDocument, order: [NodeID], terminal: NodeID, viewer: SocketRef?,
                                         resolved: [NodeID: ResolvedNode], registry: NodeRegistry,
                                         functions: [GroupID: GroupFunction], groupFunctions: [GroupFunction]) -> GeneratedShader {
        let emitted = Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry, resolved: resolved,
                                   env: .fragment,
                                   reserved: viewer == nil ? UniformLayoutBuilder.standardReserved : UniformLayoutBuilder.viewerReserved,
                                   functions: functions)
        var body = zip(emitted.bodyLines, emitted.lineOwners).map { (line: $0, owner: $1) }
        if let v = viewer, let variable = emitted.outputVars[v], let type = resolved[v.node]?.outputTypes[v.socket],
           let wrap = ViewerWrap.statement(variable: variable, type: type) {
            body.append((wrap, v.node))
        }
        let b = fragmentProgram(layout: emitted.layout, stdlib: emitted.requiredStdlib + groupFunctions.flatMap(\.requiredStdlib),
                                functions: groupFunctions, body: body, textures: emitted.textureRequests)
        return GeneratedShader(source: b.text, layout: emitted.layout, lineMap: b.map,
                               resolved: merged(resolved, groupFunctions),
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: viewer,
                               textures: emitted.textureRequests)
    }

    /// `shaderMain`'s parameter list: the stage-in, the uniform buffer, then one binding per slot.
    /// Empty `textures` reproduces the pre-texture signature byte for byte.
    static func fragmentSignature(textures: [TextureSlot]) -> String {
        let indent = String(repeating: " ", count: "fragment float4 \(fragmentFunctionName)(".count)
        var params = ["VertexOut in [[stage_in]]", "constant Uniforms &u [[buffer(0)]]"]
        params += textures.map { "texture2d<float> \($0.fragmentName) [[texture(\($0.index))]]" }
        return "fragment float4 \(fragmentFunctionName)(" + params.joined(separator: ",\n" + indent) + ") {"
    }

    /// The shape of every fragment program: includes, the uniform struct, `VertexOut`, the stdlib
    /// closure, the group functions, then `shaderMain`'s body.
    static func fragmentProgram(layout: UniformLayout, stdlib: [String], functions: [GroupFunction],
                                body: [(line: String, owner: NodeID?)],
                                textures: [TextureSlot] = []) -> SourceBuilder {
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>\nusing namespace metal;\n")
        b.add(layout.mslStruct + "\n")
        b.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in MSLStdlib.resolve(stdlib) { b.add(f.source + "\n") }
        // Each function carries its own line map; folding it in at the function's offset makes the
        // statements inside a definition addressable from the program's lines (spec §21.8).
        for f in functions { b.add(f.source, map: f.lineMap) }
        b.add(fragmentSignature(textures: textures))
        for statement in body { b.add("    " + statement.line, owner: statement.owner) }
        b.add("}")
        return b
    }

    private static func assembleStitchable(_ doc: ShaderDocument, kind: StitchableKind, order: [NodeID], terminal: NodeID,
                                           resolved: [NodeID: ResolvedNode], registry: NodeRegistry,
                                           functions: [GroupID: GroupFunction], groupFunctions: [GroupFunction]) -> GeneratedShader {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let emitted = Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry, resolved: resolved,
                                   env: .stitchableFunction, functions: functions)
        let textures = emitted.textureRequests
        // The preview binds the assets as textures; the export has none to bind and reads the layer
        // SwiftUI passes instead, so it needs its own emission (spec §21.2). Only the Layer Effect
        // gets here with textures at all — validation refuses the other two kinds.
        let exported = textures.isEmpty ? emitted
            : Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry,
                           resolved: resolved, env: .layerExport, functions: functions)
        let args = StitchableCodegen.arguments(layout: emitted.layout)
        let stdlib = MSLStdlib.resolve(emitted.requiredStdlib + groupFunctions.flatMap(\.requiredStdlib))

        func function(into b: inout SourceBuilder, forExport: Bool) {
            let e = forExport ? exported : emitted
            let color = e.inputExpressions[terminal]?["color"] ?? "float4(0.0, 0.0, 0.0, 1.0)"
            b.add(StitchableCodegen.signature(kind: kind, name: name, args: args,
                                              textures: forExport ? [] : textures, forExport: forExport) + " {")
            b.add("    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);")
            for (i, line) in e.bodyLines.enumerated() where e.lineOwners[i] != terminal {
                b.add("    " + line, owner: e.lineOwners[i])
            }
            b.add("    " + StitchableCodegen.returnStatement(kind: kind, color: color), owner: terminal)
            b.add("}")
        }

        var export = SourceBuilder()
        export.add("#include <metal_stdlib>" + (kind == .layerEffect ? "\n#include <SwiftUI/SwiftUI_Metal.h>" : "") + "\nusing namespace metal;\n")
        for f in stdlib { export.add(f.source + "\n") }
        for fn in groupFunctions { export.add(fn.source, map: fn.lineMap) }
        function(into: &export, forExport: true)

        var preview = SourceBuilder()
        preview.add("#include <metal_stdlib>\nusing namespace metal;\n")
        preview.add(emitted.layout.mslStruct + "\n")
        preview.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in stdlib { preview.add(f.source + "\n") }
        for fn in groupFunctions { preview.add(fn.source, map: fn.lineMap) }
        function(into: &preview, forExport: false)
        preview.add("")
        preview.add(fragmentSignature(textures: textures))
        for l in StitchableCodegen.previewBody(kind: kind, name: name, args: args, textures: textures) { preview.add("    " + l) }
        preview.add("}")

        return GeneratedShader(source: preview.text, layout: emitted.layout, lineMap: preview.map,
                               resolved: merged(resolved, groupFunctions),
                               fragmentFunctionName: fragmentFunctionName, target: .stitchable(kind),
                               viewer: nil, exportSource: export.text, functionName: name,
                               textures: textures)
    }
}
