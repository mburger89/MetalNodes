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

    /// A graph reading every 3D input node in its legal stage must still compile — the shims'
    /// accessor names are only right if the compiler agrees.
    @Test func everyThreeDimensionalInputCompiles() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        // Surface-legal 3D inputs, each read in turn (float3 → color widens implicitly per
        // `Conversion`, so no separate combining node is needed).
        var previous: SocketRef?
        for id in ["input.worldPosition", "input.modelPosition", "input.normal3d",
                   "input.tangent", "input.bitangent", "input.viewDirection"] {
            let n = NodeInstance(id: NodeID(), kind: .builtin(id), position: .zero)
            g.nodes[n.id] = n
            previous = SocketRef(n.id, NodeRegistry.builtin[id]!.outputs.first!.name)
        }
        g.inputs[SocketRef(terminal.id, "baseColor")] = previous
        // Vertex ID is geometry-only, and left unconnected here: only a node reachable from the
        // terminal is stage-checked (`MaterialValidation.stageDiagnostics`), so an unwired
        // geometry-only node in a surface-only graph must not fail generation or compilation.
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        g.nodes[vid.id] = vid
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let compiler = try ShaderCompiler(device: device)
        if case .failure(let message, _, _) = await compiler.compile(shader, generation: 1) {
            Issue.record("compile failed: \(message)")
        }
    }
}
