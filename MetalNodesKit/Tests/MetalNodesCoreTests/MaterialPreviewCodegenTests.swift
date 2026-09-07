import Testing
@testable import MetalNodesCore

@Suite struct MaterialPreviewCodegenTests {
    private func document(lighting: MaterialLightingModel = .lit, offset: Bool = true,
                          normal: Bool = false) -> ShaderDocument {
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
        if normal {
            let n = NodeInstance(id: NodeID(), kind: .builtin("input.normal3d"), position: .zero)
            g.nodes[n.id] = n
            g.inputs[SocketRef(terminal.id, "normal")] = SocketRef(n.id, "normal")
        }
        doc.root = g
        return doc
    }

    private func source(_ doc: ShaderDocument) throws -> String {
        try ShaderGenerator.generate(doc, target: .realityKit).source
    }

    /// The vertex function's text alone: from its signature up to the fragment function's.
    private func vertexFunction(of doc: ShaderDocument) throws -> String {
        let src = try source(doc)
        let v = try #require(src.range(of: "vertex VertexOut mn_meshVertex("))
        let f = try #require(src.range(of: "fragment float4 shaderMain("))
        return String(src[v.lowerBound..<f.lowerBound])
    }

    /// What the statement beginning `prefix` assigns, up to its `;`.
    private static func assigned(to prefix: String, in text: String) -> String? {
        guard let r = text.range(of: prefix) else { return nil }
        let rest = text[r.upperBound...]
        return rest.firstIndex(of: ";").map { String(rest[..<$0]) }
    }

    /// `v0`, `v1`, … — an emitted node's SSA output variable, as opposed to a `u.…` slot read.
    /// The whole point of both checks below: only a *wired* node produces one of these.
    private static func isSSAVariable(_ s: String) -> Bool {
        s.first == "v" && s.count > 1 && s.dropFirst().allSatisfy(\.isNumber)
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

    /// `float3 offset = float3(0.0);` and the `offset = …;` assignment are both emitted whatever
    /// the graph does, so neither substring tells a wired Position Offset from an unwired one. The
    /// discriminator is what the assignment *reads*: the geometry pass's SSA variable when a node
    /// feeds the socket, the terminal's own uniform slot when nothing does.
    @Test func theGeometryStageRunsInTheVertexFunction() throws {
        let wired = try vertexFunction(of: document(offset: true))
        #expect(wired.contains("cam.viewToProjection"))
        let assigned = try #require(Self.assigned(to: "\n    offset = ", in: wired))
        #expect(Self.isSSAVariable(assigned), "offset reads \(assigned), not a wired node")
        // The geometry pass declared that variable inside the vertex function, so the wired node's
        // statements really ran here rather than in the fragment stage.
        #expect(wired.contains("float3 \(assigned);"))

        let bare = try vertexFunction(of: document(offset: false))
        let bareAssigned = try #require(Self.assigned(to: "\n    offset = ", in: bare))
        #expect(!Self.isSSAVariable(bareAssigned), "nothing is wired, yet offset reads \(bareAssigned)")
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
    ///
    /// `float3x3(` and `tangent` both appear in the struct declarations and in the basis line
    /// whatever the graph does, so the check is that the *wired* node's SSA variable is what
    /// `tangentNormal` holds and that it reaches the shading normal through the basis.
    @Test func theNormalSocketIsResolvedThroughTheTangentBasis() throws {
        let src = try source(document(normal: true))
        let assigned = try #require(Self.assigned(to: "float3 tangentNormal = ", in: src))
        #expect(Self.isSSAVariable(assigned), "tangentNormal reads \(assigned), not a wired node")
        #expect(src.contains("float3 \(assigned);"))
        #expect(src.contains("\(assigned) = params.geometry().normal();"))
        #expect(src.contains("float3x3 basis = float3x3(normalize(in.tangent), normalize(in.bitangent), normalize(in.normal));"))
        #expect(src.contains("float3 n = normalize(basis * normalize(tangentNormal));"))

        // Unwired, the same lines carry the terminal's own slot instead — which is exactly why
        // matching the basis text alone proved nothing.
        let bare = try source(document(normal: false))
        let bareAssigned = try #require(Self.assigned(to: "float3 tangentNormal = ", in: bare))
        #expect(!Self.isSSAVariable(bareAssigned), "nothing is wired, yet tangentNormal reads \(bareAssigned)")
    }

    @Test func theStructsMatchTheirDeclaredLayout() throws {
        let src = try source(document())
        #expect(src.contains(MaterialPreviewCodegen.meshVertexStruct))
        #expect(src.contains(MaterialPreviewCodegen.cameraStruct))
        #expect(src.contains("struct Uniforms {"))
    }

    // Final review — Finding 5 (Minor, latent): the tangent took the inverse transpose.

    /// A normal is perpendicular to the surface and transforms by the inverse transpose
    /// (`cam.normalToWorld`, which `CameraUniforms` computes for exactly that). A tangent runs
    /// *along* the surface and transforms by the model matrix itself. The vertex stage used
    /// `normalToWorld` for both. Both matrices are identity today so nothing is visibly wrong, but
    /// the moment a non-identity model transform appears — the only case `normalToWorld` exists for
    /// — the inverse transpose skews the tangent out of the surface and takes the whole
    /// normal-mapping basis (`float3x3 basis = …(tangent, bitangent, normal)`) with it.
    @Test func theTangentTakesTheModelMatrixAndTheNormalTheInverseTranspose() throws {
        let fn = try vertexFunction(of: document())
        #expect(fn.contains("float3x3 modelRotation = float3x3(cam.modelToWorld[0].xyz, cam.modelToWorld[1].xyz, cam.modelToWorld[2].xyz);"))
        #expect(fn.contains("o.tangent = normalize(modelRotation * vert.tangent.xyz);"))
        #expect(!fn.contains("o.tangent = normalize(cam.normalToWorld"))
        // The normal keeps the inverse transpose — this is not a blanket swap.
        #expect(fn.contains("o.normal = normalize(cam.normalToWorld * vert.normal);"))
        // The bitangent is still derived from the transformed pair, so it follows the fix.
        #expect(fn.contains("o.bitangent = cross(o.normal, o.tangent) * vert.tangent.w;"))
    }

    @Test func generationIsDeterministic() throws {
        let doc = document()
        #expect(try source(doc) == (try source(doc)))
    }
}

@Suite struct MaterialViewerTests {
    @Test func aViewedSocketRendersAsUnlitColourOnTheMesh() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let noise = NodeInstance(id: NodeID(), kind: .builtin("noise.value"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[noise.id] = noise
        doc.root = g

        let out = NodeRegistry.builtin["noise.value"]!.outputs.first!.name
        let shader = try ShaderGenerator.generate(doc, target: .realityKit, viewer: SocketRef(noise.id, out))
        #expect(shader.target == .realityKit)
        #expect(shader.viewer != nil)
        // Unlit: the GGX helpers are not emitted, and the mesh vertex stage still is.
        #expect(!shader.source.contains("mn_ggx_distribution"))
        #expect(shader.source.contains("vertex VertexOut mn_meshVertex("))
        // The viewer range fields exist, as they do for the 2D viewer path.
        #expect(shader.layout.hasReserved("viewerMin"))
        // The viewed value *is* the emissive term, widened by the same `ViewerWrap` rule the
        // fragment path returns, and it is what the mesh shows.
        let assignment = try #require(shader.source.range(of: "float4 emissive = "))
        let emissive = shader.source[assignment.upperBound...].prefix { $0 != ";" }
        #expect(emissive.contains("u.viewerMin") && emissive.contains("u.viewerMax"))
        #expect(shader.source.contains("return float4(emissive.rgb, opacity);"))
    }

    // Final review — Finding 3 (Important): viewer widening bypassed stage legality.

    /// The widening in `assembleRealityKit` prepends the viewed node's cone to the **surface**
    /// order only, and rule 2 validates `stageOrder`'s roots, which never include the viewer's
    /// node. So viewing a geometry-only node emitted `v0 = /* ?sys.vertexID */;` into the fragment
    /// stage — while the vertex stage correctly emitted `v0 = int(geo.vertex_id());` — with no
    /// diagnostic at all.
    ///
    /// Refused rather than widened into the geometry order: spec §23.5 fixes the viewer under this
    /// target as the viewed value drawn as unlit *colour on the mesh*, which is the fragment
    /// stage's product.
    private func geometryOnlyDocument() -> (ShaderDocument, SocketRef) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[vid.id] = vid
        // Legal where it belongs: wired into the geometry socket, so nothing but the viewer is wrong.
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(vid.id, "id")
        doc.root = g
        return (doc, SocketRef(vid.id, "id"))
    }

    @Test func viewingAGeometryOnlyNodeIsRefused() throws {
        let (doc, ref) = geometryOnlyDocument()
        // Without the viewer the same document is perfectly legal — the refusal is the viewer's.
        let plain = try ShaderGenerator.generate(doc, target: .realityKit)
        #expect(plain.source.contains("int(geo.vertex_id())"))
        #expect(!plain.source.contains("?sys."))

        #expect(throws: GenerationError.self) {
            let shader = try ShaderGenerator.generate(doc, target: .realityKit, viewer: ref)
            // What the bug produced, asserted so a silent regression cannot pass here either.
            #expect(!shader.source.contains("?sys.vertexID"))
        }
        do {
            _ = try ShaderGenerator.generate(doc, target: .realityKit, viewer: ref)
            Issue.record("expected a refusal")
        } catch {
            guard case .invalid(let diags) = error else { return }
            #expect(diags.contains { $0.severity == .error && $0.message.contains("Vertex ID")
                                     && $0.message.contains("cannot be viewed") })
            // Anchored on the node, so the canvas can point at it.
            #expect(diags.first?.node == ref.node)
        }
    }

    /// A geometry-only node reached *through a group instance* is refused too — the widening walks
    /// into definitions exactly as rule 2 does.
    @Test func viewingAGroupThatHidesAGeometryOnlyNodeIsRefused() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var def = GroupDefinition(id: GroupID(), name: "Hidden",
                                  outputs: [SocketDecl(name: "out", type: .concrete(.int))])
        var inner = Graph()
        let gin = NodeInstance(id: NodeID(), kind: .groupInput, position: .zero)
        let gout = NodeInstance(id: NodeID(), kind: .groupOutput, position: .zero)
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        for n in [gin, gout, vid] { inner.nodes[n.id] = n }
        inner.inputs[SocketRef(gout.id, "out")] = SocketRef(vid.id, "id")
        def.graph = inner
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[instance.id] = instance
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(instance.id, "out")
        doc.root = g

        #expect(throws: GenerationError.self) {
            _ = try ShaderGenerator.generate(doc, target: .realityKit, viewer: SocketRef(instance.id, "out"))
        }
    }

    /// The negative: a stage-agnostic node, and a surface-legal 3D input, still view fine.
    @Test func viewingASurfaceLegalNodeStillWorks() throws {
        for id in ["noise.value", "input.worldPosition", "input.viewDirection"] {
            var doc = ShaderDocument()
            doc.settings.target = .realityKit
            var g = Graph()
            let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
            let n = NodeInstance(id: NodeID(), kind: .builtin(id), position: .zero)
            g.nodes[terminal.id] = terminal
            g.nodes[n.id] = n
            doc.root = g
            let out = NodeRegistry.builtin[id]!.outputs.first!.name
            let shader = try ShaderGenerator.generate(doc, target: .realityKit, viewer: SocketRef(n.id, out))
            #expect(shader.viewer != nil, "\(id)")
            #expect(!shader.source.contains("?sys."), "\(id)")
        }
    }
}
