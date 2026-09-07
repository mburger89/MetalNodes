import Testing
@testable import MetalNodesCore

@Suite(.disabled("enabled by Task 9, which wires the .realityKit branch into ShaderGenerator"))
struct MaterialPreviewCodegenTests {
    private func document(lighting: MaterialLightingModel = .lit, offset: Bool = true) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(0, 1, 0, 1))
        g.nodes[terminal.id] = terminal
        g.nodes[color.id] = color
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        if offset {
            let v = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
            g.nodes[v.id] = v
            g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(v.id, "out")
        }
        doc.root = g
        return doc
    }

    private func source(_ doc: ShaderDocument) throws -> String {
        try ShaderGenerator.generate(doc, target: .realityKit).source
    }

    @Test func theProgramHasBothStagesAndNoRealityKitHeader() throws {
        let src = try source(document())
        #expect(src.contains("vertex VertexOut mn_meshVertex("))
        #expect(src.contains("fragment float4 shaderMain("))
        // Those headers ship with Xcode, not with the OS; the runtime compiler cannot find them.
        #expect(!src.contains("RealityKit"))
        #expect(!src.contains("[[visible]]"))
    }

    @Test func bufferIndicesMatchTheSpec() throws {
        let src = try source(document())
        #expect(src.contains("device const MeshVertex *verts [[buffer(0)]]"))
        #expect(src.contains("constant CameraUniforms &cam [[buffer(1)]]"))
        #expect(src.contains("constant Uniforms &u [[buffer(2)]]"))     // vertex stage
        #expect(src.contains("constant Uniforms &u [[buffer(0)]]"))     // fragment stage
        #expect(src.contains("constant CameraUniforms &cam [[buffer(1)]]"))
    }

    @Test func theGeometryStageRunsInTheVertexFunction() throws {
        let src = try source(document(offset: true))
        let vertexRange = try #require(src.range(of: "vertex VertexOut mn_meshVertex("))
        let fragmentRange = try #require(src.range(of: "fragment float4 shaderMain("))
        let vertexBody = String(src[vertexRange.lowerBound..<fragmentRange.lowerBound])
        #expect(vertexBody.contains("positionOffset") || vertexBody.contains("offset"))
        #expect(vertexBody.contains("cam.viewToProjection"))
    }

    @Test func withoutAGeometryStageTheVertexFunctionStillExists() throws {
        let src = try source(document(offset: false))
        #expect(src.contains("vertex VertexOut mn_meshVertex("))
    }

    @Test func litShadesWithGGXAndUnlitDoesNot() throws {
        let lit = try source(document(lighting: .lit))
        #expect(lit.contains("mn_ggx_distribution"))
        #expect(lit.contains("mn_smith_visibility"))
        #expect(lit.contains("mn_schlick_fresnel"))

        let unlit = try source(document(lighting: .unlit))
        #expect(!unlit.contains("mn_ggx_distribution"))
        #expect(unlit.contains("emissive"))
    }

    /// The tangent-space normal socket must be resolved against the interpolated basis before it
    /// can shade — otherwise a wired Normal produces a lit sphere that ignores it.
    @Test func theNormalSocketIsResolvedThroughTheTangentBasis() throws {
        let src = try source(document())
        #expect(src.contains("float3x3(") && src.contains("tangent"))
    }

    @Test func theStructsMatchTheirDeclaredLayout() throws {
        let src = try source(document())
        #expect(src.contains(MaterialPreviewCodegen.meshVertexStruct))
        #expect(src.contains(MaterialPreviewCodegen.cameraStruct))
        #expect(src.contains("struct Uniforms {"))
    }

    @Test func generationIsDeterministic() throws {
        let doc = document()
        #expect(try source(doc) == (try source(doc)))
    }
}
