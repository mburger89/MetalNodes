import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct MaterialCompileTests {
    /// Every 3D program shape must reach a linked pipeline — that is what a preview failing
    /// silently would look like, and no unit test on the source text can catch it.
    ///
    /// `PreviewMesh` plays no part in codegen (`ShaderGenerator.generate` never takes one — the
    /// mesh only matters to the renderer's vertex buffer), so it is not a test parameter here;
    /// the two axes that do change the generated program are lighting model and whether a
    /// geometry modifier is present. Swift Testing's `arguments:` cross-product overload takes at
    /// most two collections, which is the other reason this stays two-dimensional.
    @Test(arguments: [MaterialLightingModel.lit, .unlit], [true, false])
    func everyThreeDimensionalProgramCompiles(_ lighting: MaterialLightingModel,
                                              _ withGeometry: Bool) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(0.2, 0.6, 1, 1))
        g.nodes[terminal.id] = terminal
        g.nodes[color.id] = color
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        g.inputs[SocketRef(terminal.id, "emissive")] = SocketRef(color.id, "out")
        if withGeometry {
            let noise = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
            g.nodes[noise.id] = noise
            g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(noise.id, "out")
        }
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success(let pipeline) = result else {
            Issue.record("compile failed: \(result)")
            return
        }
        #expect(pipeline.depthStencilState != nil)
    }

    /// Every surface-legal 3D input node must genuinely reach the terminal and produce its own
    /// accessor call — one graph per node, each wired *directly* into `baseColor`
    /// (`TopoSort.order` walks upstream from the terminal only, so a node left unconnected is
    /// eliminated before codegen and would prove nothing; see Fix round 1 below). Asserting the
    /// exact accessor substring in `shader.source`, not just a successful compile, is what rules
    /// out the previous vacuous version: a compile can succeed while silently reading the default
    /// literal instead of the node under test.
    @Test func everyThreeDimensionalSurfaceInputCompiles() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let compiler = try ShaderCompiler(device: device)
        // (node id, expected accessor call in the generated surface-stage source).
        let nodes: [(id: String, accessor: String)] = [
            ("input.worldPosition", "params.geometry().world_position()"),
            ("input.modelPosition", "params.geometry().model_position()"),
            ("input.normal3d", "params.geometry().normal()"),
            ("input.tangent", "params.geometry().tangent()"),
            ("input.bitangent", "params.geometry().bitangent()"),
            ("input.viewDirection", "params.geometry().view_direction()"),
        ]
        for (id, accessor) in nodes {
            var doc = ShaderDocument()
            doc.settings.target = .realityKit
            var g = Graph()
            let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
            let n = NodeInstance(id: NodeID(), kind: .builtin(id), position: .zero)
            g.nodes[terminal.id] = terminal
            g.nodes[n.id] = n
            // float3 → color widens implicitly per `Conversion`, so the node's own output wires
            // straight into `baseColor` with no combining node.
            g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(n.id, NodeRegistry.builtin[id]!.outputs.first!.name)
            doc.root = g

            let shader = try ShaderGenerator.generate(doc, target: .realityKit)
            #expect(shader.source.contains(accessor), "\(id): expected `\(accessor)` in generated source")
            if case .failure(let message, _, _) = await compiler.compile(shader, generation: 1) {
                Issue.record("\(id) compile failed: \(message)")
            }
        }
    }

    /// The geometry-only mirror of the test above: Vertex ID is legal only in the geometry stage
    /// (`stages: [.geometry]`), so it is wired into `positionOffset` — an `int` output widening to
    /// `float3` per `Conversion` — rather than `baseColor`. Same proof shape: assert the accessor
    /// substring, then compile.
    @Test func vertexIDCompilesInTheGeometryStage() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[vid.id] = vid
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(vid.id, "id")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        #expect(shader.source.contains("geo.vertex_id()"), "expected `geo.vertex_id()` in generated source")
        let compiler = try ShaderCompiler(device: device)
        if case .failure(let message, _, _) = await compiler.compile(shader, generation: 1) {
            Issue.record("input.vertexID compile failed: \(message)")
        }
    }

    /// `{sys.time}` always spells as `params.uniforms().time()` (`EmitEnvironment.materialSys`),
    /// matching RealityKit's own `geometry_parameters`. The preview's vertex function only ever
    /// declared a `geo` shim, never a `params` one, so any RealityKit document reading Time from
    /// its geometry stage failed the *GPU* compile with `use of undeclared identifier 'params'`
    /// even though `ShaderGenerator.generate` alone succeeds — this is the class of defect
    /// `everyThreeDimensionalProgramCompiles` above cannot see, because its `withGeometry` case
    /// wires a constant `input.float3` rather than a system value read from the geometry stage.
    /// `time` (float) widens to `positionOffset` (float3) via `Conversion`'s scalar broadcast, so
    /// no combining node is needed to reach the type-correct socket directly.
    @Test func timeCompilesInTheGeometryStage() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[time.id] = time
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(time.id, "time")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        #expect(shader.source.contains("params.uniforms().time()"),
                "expected `params.uniforms().time()` in generated source")
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success = result else {
            Issue.record("input.time in the geometry stage failed to compile: \(result)")
            return
        }
    }

    /// The call-site mirror of the test above: `Emitter`'s `.group(let gid)` case always passes
    /// `env.sys["time"]` as a positional argument to a group function call (`Emitter.swift`,
    /// `var args = [env.sys["uv"] ?? …, env.sys["time"] ?? …, …]`) — unconditionally, whether or
    /// not the callee's own body reads time. So a group instance in the geometry stage embeds
    /// `params.uniforms().time()` in its call line even when this trivial callee never mentions
    /// time at all, and the same undeclared-`params` failure applies. Proves the fix's textual
    /// `bodyLines.contains(where: …)` check catches an inline call argument, not only a standalone
    /// `v0 = params.uniforms().time();` assignment.
    @Test func groupCallInTheGeometryStageCompilesEvenWhenTheCalleeIgnoresTime() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var def = GroupDefinition(id: GroupID(), name: "Constant",
                                  outputs: [SocketDecl(name: "out", type: .concrete(.float3))])
        var inner = Graph()
        let gin = NodeInstance(id: NodeID(), kind: .groupInput, position: .zero)
        let gout = NodeInstance(id: NodeID(), kind: .groupOutput, position: .zero)
        let constant = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [gin, gout, constant] { inner.nodes[n.id] = n }
        inner.inputs[SocketRef(gout.id, "out")] = SocketRef(constant.id, "out")
        def.graph = inner
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[instance.id] = instance
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(instance.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        #expect(shader.source.contains("params.uniforms().time()"),
                "expected the call site to still pass `params.uniforms().time()`")
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success = result else {
            Issue.record("group call in the geometry stage failed to compile: \(result)")
            return
        }
    }

    /// The mirror of `pipeline.depthStencilState != nil` above: the *fullscreen* path must not
    /// grow one just because `.realityKit` did. Nothing else guards this — the depth attachment
    /// is easy to attach unconditionally by accident, and a 2D pipeline built with one is a
    /// contract break `MTKView.depthStencilPixelFormat` won't catch until draw time.
    @Test func aTwoDimensionalProgramGetsNoDepthState() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let compiler = try ShaderCompiler(device: device)
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        guard case .success(let pipeline) = await compiler.compile(shader, generation: 1) else {
            Issue.record("expected success")
            return
        }
        #expect(pipeline.depthStencilState == nil)
    }
}
