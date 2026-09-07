import Testing
@testable import MetalNodesCore

@Suite struct MaterialStagePartitionTests {
    /// A document with `input.float` → baseColor and `input.float3` → positionOffset.
    private func bothStages() -> (ShaderDocument, terminal: NodeID, colorNode: NodeID, offsetNode: NodeID) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let colorNode = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        let offsetNode = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, colorNode, offsetNode] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(colorNode.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offsetNode.id, "out")
        doc.root = g
        return (doc, terminal.id, colorNode.id, offsetNode.id)
    }

    @Test func eachStageSeesOnlyItsOwnUpstream() {
        let (doc, terminal, colorNode, offsetNode) = bothStages()
        let surface = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .surface)
        let geometry = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .geometry)
        #expect(surface.contains(colorNode))
        #expect(!surface.contains(offsetNode))
        #expect(geometry.contains(offsetNode))
        #expect(!geometry.contains(colorNode))
    }

    @Test func theTerminalIsLastInEveryStageOrder() {
        let (doc, terminal, _, _) = bothStages()
        for stage in MaterialStage.allCases {
            let order = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: stage)
            #expect(order.last == terminal, "\(stage)")
            #expect(order.filter { $0 == terminal }.count == 1, "\(stage)")
        }
    }

    @Test func anEmptyStageIsJustTheTerminal() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        doc.root = g
        #expect(MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry) == [terminal.id])
    }

    /// A node feeding both stages appears in both orders — it is computed once per stage,
    /// because the stages are different shader invocations that share no variables.
    @Test func aSharedNodeAppearsInBothOrders() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        let vec = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, time, vec] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(time.id, "time")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(vec.id, "out")
        doc.root = g
        let surface = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let geometry = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry)
        #expect(surface.contains(time.id))
        #expect(geometry.contains(vec.id))
    }
}

@Suite struct SharedBindingsTests {
    /// Both stages must emit against one `Uniforms` struct, because the preview binds one buffer
    /// to both the generated vertex function and the fragment function.
    @Test func bothStagesEmitAgainstOneLayout() {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var a = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        a.params["value"] = .float(0.25)
        var b = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        b.params["value"] = .float3(.init(1, 2, 3))
        for n in [terminal, a, b] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(a.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(b.id, "out")
        doc.root = g

        let surfaceOrder = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let geometryOrder = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry)
        func emit(_ order: [NodeID], shared: Emitter.SharedBindings?) -> Emitter.Output {
            let (resolved, diags) = TypeResolver.resolve(g, path: .root, document: doc, registry: .builtin, order: order)
            #expect(diags.isEmpty)
            return Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                resolved: resolved, env: .fragment, shared: shared)
        }
        let shared = MaterialCodegen.sharedBindings(surface: emit(surfaceOrder, shared: nil),
                                                   geometry: emit(geometryOrder, shared: nil))
        let s = emit(surfaceOrder, shared: shared)
        let gm = emit(geometryOrder, shared: shared)
        #expect(s.layout == gm.layout)
        #expect(s.layout == shared.layout)
        // Both slots live in the one struct even though neither stage alone requests both.
        let paths = Set(shared.layout.fields.compactMap(\.path))
        #expect(paths.contains(ParamPath(node: a.id, param: "value")))
        #expect(paths.contains(ParamPath(node: b.id, param: "value")))
    }

    @Test func sharedTextureSlotsKeepTheirIndices() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        for n in [terminal, sample] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(sample.id, "color")
        doc.root = g
        let order = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let (resolved, _) = TypeResolver.resolve(g, path: .root, document: doc, registry: .builtin, order: order)
        let first = Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                 resolved: resolved, env: .fragment)
        let shared = MaterialCodegen.sharedBindings(surface: first, geometry: first)
        let again = Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                 resolved: resolved, env: .fragment, shared: shared)
        #expect(again.textureRequests == shared.order)
        #expect(again.textureRequests.first?.index == 0)
    }
}

@Suite struct MaterialSetterTests {
    @Test func everySurfaceSocketMapsToItsSetterWithTheRightPrecision() {
        #expect(MaterialCodegen.setterStatement(socket: "baseColor", expression: "v0") == "surface.set_base_color(half3(v0.rgb));")
        #expect(MaterialCodegen.setterStatement(socket: "emissive", expression: "v1") == "surface.set_emissive_color(half3(v1.rgb));")
        #expect(MaterialCodegen.setterStatement(socket: "roughness", expression: "v2") == "surface.set_roughness(half(v2));")
        #expect(MaterialCodegen.setterStatement(socket: "metallic", expression: "v3") == "surface.set_metallic(half(v3));")
        #expect(MaterialCodegen.setterStatement(socket: "opacity", expression: "v4") == "surface.set_opacity(half(v4));")
        #expect(MaterialCodegen.setterStatement(socket: "occlusion", expression: "v5") == "surface.set_ambient_occlusion(half(v5));")
        #expect(MaterialCodegen.setterStatement(socket: "specular", expression: "v6") == "surface.set_specular(half(v6));")
        // The one float3 setter — tangent space, normalized by RealityKit before storing.
        #expect(MaterialCodegen.setterStatement(socket: "normal", expression: "v7") == "surface.set_normal(v7);")
        #expect(MaterialCodegen.setterStatement(socket: "positionOffset", expression: "v8") == "geo.set_model_position_offset(v8);")
        #expect(MaterialCodegen.setterStatement(socket: "nonsense", expression: "v9") == nil)
    }

    @Test func everyTerminalSocketHasASetter() {
        for decl in NodeRegistry.builtin["output.material"]!.inputs {
            #expect(MaterialCodegen.setterStatement(socket: decl.name, expression: "x") != nil, "\(decl.name)")
        }
    }

    @Test func functionNamesSuffixTheExportName() {
        let n = MaterialCodegen.functionNames(exportName: "myMaterial")
        #expect(n.surface == "myMaterial_surface")
        #expect(n.geometry == "myMaterial_geometry")
    }
}

@Suite struct MaterialExportSourceTests {
    /// One node wired to Base Color, one to Position Offset, one parameter to bake.
    private func document() -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "testMaterial"
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(1, 0, 0, 1))
        var offset = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        offset.params["value"] = .float3(.init(0, 0.25, 0))
        for n in [terminal, color, offset] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offset.id, "out")
        doc.root = g
        return doc
    }

    private func source(_ doc: ShaderDocument) throws -> String {
        try ShaderGenerator.generate(doc, target: .realityKit).exportSource ?? ""
    }

    @Test func bothFunctionsAreEmittedWithTheRealityKitHeader() throws {
        let src = try source(document())
        #expect(src.contains("#include <RealityKit/RealityKit.h>"))
        #expect(src.contains("[[visible]]\nvoid testMaterial_surface(realitykit::surface_parameters params)"))
        #expect(src.contains("[[visible]]\nvoid testMaterial_geometry(realitykit::geometry_parameters params)"))
    }

    @Test func theSurfaceFunctionSetsAllEightProperties() throws {
        let src = try source(document())
        for setter in ["set_base_color", "set_normal", "set_roughness", "set_metallic",
                       "set_emissive_color", "set_opacity", "set_ambient_occlusion", "set_specular"] {
            #expect(src.contains(setter), "\(setter)")
        }
    }

    @Test func parametersAreBakedAsLiteralsAndNoUniformBufferIsRead() throws {
        let src = try source(document())
        #expect(src.contains("float4(1.0, 0.0, 0.0, 1.0)"))
        #expect(src.contains("float3(0.0, 0.25, 0.0)"))
        #expect(!src.contains("struct Uniforms"))
        #expect(!src.contains("u."))
    }

    /// Time is the one live value: it maps natively and must not be baked.
    @Test func timeStaysLive() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        doc.root.nodes[time.id] = time
        doc.root.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(time.id, "time")
        #expect(try source(doc).contains("params.uniforms().time()"))
    }

    @Test func anUnwiredGeometryStageEmitsNoGeometryFunction() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        doc.root.inputs[SocketRef(terminal.id, "positionOffset")] = nil
        let src = try source(doc)
        #expect(src.contains("_surface"))
        #expect(!src.contains("_geometry"))
    }

    @Test func unlitEmitsOnlyTheEmissiveSetter() throws {
        var doc = document()
        doc.settings.lightingModel = .unlit
        let src = try source(doc)
        #expect(src.contains("set_emissive_color"))
        #expect(!src.contains("set_base_color"))
        #expect(!src.contains("set_roughness"))
    }

    @Test func aTextureSampleReadsTheCustomSlot() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        doc.root.nodes[sample.id] = sample
        doc.root.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(sample.id, "color")
        let src = try source(doc)
        #expect(src.contains("params.textures().custom()"))
        #expect(src.contains("constexpr sampler"))
    }

    /// A texture reaching only Base Color must not cost the geometry function an unused local:
    /// `xcrun metal -c` warns on `texture2d<half> tex0 = …` that nothing in that function reads.
    @Test func aTextureReachingOnlyTheSurfaceStageDeclaresItsLocalOnlyThere() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        doc.root.nodes[sample.id] = sample
        doc.root.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(sample.id, "color")
        // positionOffset stays wired to `document()`'s float3 node — a real geometry function,
        // but one with nothing texture-driven inside it.
        let src = try source(doc)
        let geometryStart = try #require(src.range(of: "void testMaterial_geometry")).lowerBound
        #expect(src[..<geometryStart].contains("texture2d<half> tex0"))
        #expect(!src[geometryStart...].contains("texture2d<half> tex0"))
    }

    /// The inverse: a texture reaching only Position Offset must not cost the surface function an
    /// unused local either.
    @Test func aTextureReachingOnlyTheGeometryStageDeclaresItsLocalOnlyThere() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        doc.root.nodes[sample.id] = sample
        // `color` (float4) narrows to the float3 Position Offset wants; `baseColor` stays wired
        // to `document()`'s plain color node, which samples nothing.
        doc.root.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(sample.id, "color")
        let src = try source(doc)
        let geometryStart = try #require(src.range(of: "void testMaterial_geometry")).lowerBound
        #expect(!src[..<geometryStart].contains("texture2d<half> tex0"))
        #expect(src[geometryStart...].contains("texture2d<half> tex0"))
    }

    /// The generated source must be stable: same document, same bytes, every time.
    @Test func generationIsDeterministic() throws {
        let doc = document()
        #expect(try source(doc) == (try source(doc)))
    }
}
