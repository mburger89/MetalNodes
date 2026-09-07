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
    /// The exported `[[visible]]` function per stage, when `target` is `.realityKit` (spec §23.4).
    /// Empty for every other target. A stage with nothing to do has no entry.
    public let stageFunctionNames: [MaterialStage: String]
    /// The vertex function the pipeline pairs with `fragmentFunctionName`. The static fullscreen
    /// triangle for every 2D program; a generated one for the 3D preview (spec §23.5).
    ///
    /// `MetalNodesCore` cannot import `MetalNodesRender`, so the 2D default is the string literal
    /// rather than `VertexStage.functionName`; a Render test asserts the two never drift.
    public let vertexFunctionName: String

    public init(source: String, layout: UniformLayout, lineMap: LineMap, resolved: [NodeID: ResolvedNode],
                fragmentFunctionName: String, target: OutputTarget, viewer: SocketRef? = nil,
                viewerPath: [NodeID] = [], exportSource: String? = nil, functionName: String = "",
                textures: [TextureSlot] = [], stageFunctionNames: [MaterialStage: String] = [:],
                vertexFunctionName: String = "mn_fullscreenVertex") {
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
        self.stageFunctionNames = stageFunctionNames
        self.vertexFunctionName = vertexFunctionName
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
        // Validation above guarantees the target's terminal exists; a RealityKit document has no
        // Fragment Output and vice versa, so the lookup must know which one to find (spec §23.2).
        let terminal = GraphValidator.terminal(in: doc.root, target: target)!

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
        //
        // Known M7 limitation: a *dived* viewer under `.realityKit` takes this branch too and
        // yields a 2D fullscreen program rather than the unlit-on-mesh preview §23.5 describes. It
        // is self-consistent — the result carries `target: .fragment` and the default fullscreen
        // vertex function name, so the renderer runs the 2D path over it — but it is not what the
        // spec asks for. Restructuring the view-variant machinery for the two-stage target is an
        // M8 item; a root-level viewer, which is the one the editor offers under this target, does
        // reach `assembleRealityKit` below.
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

        // A viewer is a preview concept (spec §19.3): a 2D target previews it through the fragment
        // program, and the 3D target renders it as unlit colour on the mesh (spec §23.5) — a
        // fullscreen program has no terminal to run to under `.realityKit`.
        let effectiveTarget: OutputTarget = viewer == nil || target == .realityKit ? target : .fragment
        switch effectiveTarget {
        case .fragment:
            return assembleFragment(doc, order: order, terminal: terminal, viewer: viewer, resolved: resolved, registry: registry,
                                    functions: functions, groupFunctions: groupFunctions)
        case .stitchable(let kind):
            return try assembleStitchable(doc, kind: kind, order: order, terminal: terminal, resolved: resolved, registry: registry,
                                          functions: functions, groupOrder: groupOrder, groupFunctions: groupFunctions)
        case .realityKit:
            // `order` and `resolved` are deliberately not passed: the whole-graph order the caller
            // computed spans both stages at once, which is exactly what this target must not do.
            return try assembleRealityKit(doc, terminal: terminal, viewer: viewer, registry: registry,
                                          functions: functions, groupFunctions: groupFunctions)
        }
    }

    /// The RealityKit target (spec §23.4): two passes over one graph, one shared set of bindings,
    /// two products — a 3D preview program in `source` and two `[[visible]]` functions in
    /// `exportSource`.
    private static func assembleRealityKit(_ doc: ShaderDocument, terminal: NodeID, viewer: SocketRef?,
                                           registry: NodeRegistry,
                                           functions: [GroupID: GroupFunction],
                                           groupFunctions: [GroupFunction]) throws(GenerationError) -> GeneratedShader {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        var orders: [MaterialStage: [NodeID]] = [
            .surface: MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .surface),
            .geometry: MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .geometry),
        ]
        if let v = viewer, doc.root.nodes[v.node] != nil {
            // The viewed node may feed nothing; the surface pass must still compute it.
            //
            // This widening reaches all six emissions, the two export ones included, so a viewed
            // node that feeds nothing would leave dead statements in `exportSource`. Harmless and
            // unreachable: `ShaderExport.files` always generates with `viewer: nil`, and the
            // widened statements are pure SSA assignments with no side effect even if it did not.
            // Emitting the export from unwidened orders would mean a fourth and fifth pass and a
            // second layout, which is a worse trade than a comment.
            var surface = TopoSort.order(doc.root, from: v.node)
            // …but the surface stage is still the surface stage. Rule 2 validates the roots
            // `stageOrder` produces, which never include the viewer's node, so without this a
            // geometry-only node like Vertex ID viewed here reached `materialSys(for: .surface)`,
            // which has no key for it, and emitted `v0 = /* ?sys.vertexID */;` with no diagnostic.
            //
            // Refused rather than widened into the *geometry* order, because spec §23.5 fixes what
            // a viewer means under this target: the viewed value is drawn as unlit colour on the
            // mesh, and colour is what the fragment stage — the surface pass — produces. Computing
            // it per-vertex instead would need a new interpolant on `VertexOut` to carry it across,
            // and the value would arrive smeared by interpolation: a viewed `vertex_id` would read
            // as a gradient between corners rather than as the integer it is. A geometry-only node
            // has no viewable value here, and saying so is better than inventing one.
            let illegal = MaterialValidation.stageViolations(order: surface, in: doc, registry: registry,
                                                             stage: .surface) { title in
                "\(title) cannot be viewed in a RealityKit material — a viewed value is drawn as colour on the mesh, which only the surface stage produces"
            }
            if !illegal.isEmpty { throw .invalid(illegal) }
            let existing = Set(surface)
            surface += orders[.surface]!.filter { !existing.contains($0) }
            orders[.surface] = surface
        }
        // A viewed socket is shown flat, whatever the document's model asks for (spec §23.5).
        let lighting: MaterialLightingModel = viewer == nil ? doc.settings.lightingModel : .unlit
        let reserved = viewer == nil ? UniformLayoutBuilder.standardReserved : UniformLayoutBuilder.viewerReserved

        // Types are resolved once per stage and reused by all three passes over that stage.
        // Node ids are unique document-wide, so the two maps cannot disagree where they overlap.
        var types: [NodeID: ResolvedNode] = [:]
        for stage in MaterialStage.allCases {
            let (r, diags) = TypeResolver.resolve(doc.root, path: .root, document: doc,
                                                  registry: registry, order: orders[stage]!)
            if !diags.isEmpty { throw .invalid(diags) }
            types.merge(r) { $1 }
        }

        /// One pass. `env` decides the accessors; `shared` imposes the union bindings.
        func emit(_ stage: MaterialStage, env: EmitEnvironment, shared: Emitter.SharedBindings?) -> Emitter.Output {
            Emitter.emit(order: orders[stage]!, graph: doc.root, path: .root, document: doc, registry: registry,
                         resolved: types, env: env, reserved: reserved, functions: functions, shared: shared)
        }

        // Round 1: collect requests. Round 2: emit against their union, so both stages name the
        // same uniform fields and the same texture slots (spec §23.4).
        let probeSurface = emit(.surface, env: .realityKitSurface, shared: nil)
        let probeGeometry = emit(.geometry, env: .realityKitGeometry, shared: nil)
        let shared = MaterialCodegen.sharedBindings(surface: probeSurface, geometry: probeGeometry, reserved: reserved)

        let previewSurface = emit(.surface, env: .realityKitSurface, shared: shared)
        let previewGeometry = emit(.geometry, env: .realityKitGeometry, shared: shared)

        // The export reads no uniform buffer: the same environments with a literal speller.
        let baked = EmitEnvironment.bakedUniforms(layout: shared.layout, document: doc, registry: registry)
        func bake(_ env: EmitEnvironment) -> EmitEnvironment {
            EmitEnvironment(uniform: baked, sys: env.sys, textureSample: env.textureSample,
                            textureName: env.textureName, usesLayer: env.usesLayer)
        }
        let exportSurface = emit(.surface, env: bake(.realityKitSurface), shared: shared)
        let exportGeometry = emit(.geometry, env: bake(.realityKitGeometry), shared: shared)

        let viewerExpression: String? = viewer.flatMap { v in
            guard let variable = previewSurface.outputVars[v],
                  let type = types[v.node]?.outputTypes[v.socket] else { return nil }
            return ViewerWrap.expression(variable: variable, type: type)
        }

        let preview = MaterialPreviewCodegen.program(
            surface: previewSurface, geometry: previewGeometry, groupFunctions: groupFunctions,
            terminal: terminal, layout: shared.layout, lighting: lighting,
            textures: shared.order, viewerExpression: viewerExpression)
        // The export always uses the document's model, never the viewer's.
        let export = MaterialCodegen.exportSource(
            surface: exportSurface, geometry: exportGeometry, groupFunctions: groupFunctions,
            terminal: terminal, lighting: doc.settings.lightingModel, exportName: doc.settings.exportName,
            textures: shared.order)

        let names = MaterialCodegen.functionNames(exportName: doc.settings.exportName)
        var stageNames: [MaterialStage: String] = [.surface: names.surface]
        if MaterialCodegen.hasGeometryWork(exportGeometry, terminal: terminal) {
            stageNames[.geometry] = names.geometry
        }

        return GeneratedShader(source: preview.text, layout: shared.layout, lineMap: preview.map,
                               resolved: merged(types, groupFunctions),
                               fragmentFunctionName: fragmentFunctionName, target: .realityKit,
                               viewer: viewer, exportSource: export, functionName: name,
                               textures: shared.order, stageFunctionNames: stageNames,
                               vertexFunctionName: MaterialPreviewCodegen.vertexFunctionName)
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
                                           functions: [GroupID: GroupFunction], groupOrder: [GroupID],
                                           groupFunctions: [GroupFunction]) throws(GenerationError) -> GeneratedShader {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let emitted = Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry, resolved: resolved,
                                   env: .stitchableFunction, functions: functions)
        let textures = emitted.textureRequests
        // The preview binds the assets as textures; the export has none to bind and reads the layer
        // SwiftUI passes instead, so it needs its own emission (spec §21.2).
        //
        // Every reachable definition whose *transitive* body samples gets a `_layer` variant —
        // `textureParams` already carries containment transitively, so a definition that only
        // instantiates a sampling one is in this list too. `groupOrder` is inner-first, so each
        // variant is built after the variants it calls and can name them (spec §22.7).
        var layerFunctions: [GroupID: GroupFunction] = [:]
        if kind == .layerEffect, !textures.isEmpty {
            for gid in groupOrder where !(functions[gid]?.textureParams.isEmpty ?? true) {
                layerFunctions[gid] = try GroupCodegen.function(for: doc.definitions[gid]!, document: doc, registry: registry,
                                                                functions: functions, layer: true, layerFunctions: layerFunctions)
            }
        }
        /// What the export splices in: the layer variant where there is one, the normal function
        /// otherwise. Identical to `groupFunctions` for every target but the Layer Effect.
        let exportFunctions = groupOrder.compactMap { layerFunctions[$0] ?? functions[$0] }
        let exported = textures.isEmpty ? emitted
            : Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry,
                           resolved: resolved, env: .layerExport, functions: functions,
                           layerFunctions: layerFunctions)
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
        for fn in exportFunctions { export.add(fn.source, map: fn.lineMap) }
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
