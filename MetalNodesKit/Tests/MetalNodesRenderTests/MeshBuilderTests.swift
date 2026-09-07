import Testing
import simd
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct MeshBuilderTests {
    @Test(arguments: PreviewMesh.allCases)
    func everyMeshIsNonEmptyAndWellIndexed(_ mesh: PreviewMesh) {
        let (vertices, indices) = MeshBuilder.build(mesh)
        #expect(vertices.count >= 4, "\(mesh)")
        #expect(indices.count % 3 == 0, "\(mesh)")
        #expect(!indices.isEmpty, "\(mesh)")
        for i in indices { #expect(Int(i) < vertices.count, "\(mesh) index \(i)") }
    }

    @Test(arguments: PreviewMesh.allCases)
    func normalsAreUnitLength(_ mesh: PreviewMesh) {
        for v in MeshBuilder.build(mesh).vertices {
            #expect(abs(simd_length(v.normal) - 1) < 1e-3, "\(mesh)")
        }
    }

    @Test(arguments: PreviewMesh.allCases)
    func tangentsAreUnitLengthAndPerpendicularToNormals(_ mesh: PreviewMesh) {
        for v in MeshBuilder.build(mesh).vertices {
            #expect(abs(simd_length(v.tangent.xyz) - 1) < 1e-3, "\(mesh)")
            #expect(abs(simd_dot(v.tangent.xyz, v.normal)) < 1e-3, "\(mesh)")
            #expect(abs(abs(v.tangent.w) - 1) < 1e-6, "\(mesh) handedness")
        }
    }

    @Test(arguments: PreviewMesh.allCases)
    func uvsStayInsideTheUnitSquare(_ mesh: PreviewMesh) {
        for v in MeshBuilder.build(mesh).vertices {
            #expect(v.uv.x >= -1e-4 && v.uv.x <= 1 + 1e-4, "\(mesh)")
            #expect(v.uv.y >= -1e-4 && v.uv.y <= 1 + 1e-4, "\(mesh)")
        }
    }

    @Test(arguments: PreviewMesh.allCases)
    func everyMeshFitsTheUnitBall(_ mesh: PreviewMesh) {
        // The camera's default distance assumes a roughly unit-radius model.
        for v in MeshBuilder.build(mesh).vertices {
            #expect(simd_length(v.position) <= 1.75, "\(mesh)")
        }
    }

    /// A face's winding must agree with its own vertex normals, or the renderer's back-face
    /// culling (counter-clockwise front-facing) makes the mesh render inside-out or vanish.
    /// Skips zero-area (degenerate) triangles explicitly — e.g. the triangle fan collapsing at
    /// a sphere's poles — rather than letting a near-zero cross product pass or fail by chance.
    @Test(arguments: PreviewMesh.allCases)
    func triangleWindingMatchesVertexNormals(_ mesh: PreviewMesh) {
        let (vertices, indices) = MeshBuilder.build(mesh)
        var nonDegenerateCount = 0
        var i = 0
        while i < indices.count {
            let a = vertices[Int(indices[i])]
            let b = vertices[Int(indices[i + 1])]
            let c = vertices[Int(indices[i + 2])]
            let faceNormal = simd_cross(b.position - a.position, c.position - a.position)
            if simd_length(faceNormal) > 1e-6 {
                nonDegenerateCount += 1
                let averageNormal = a.normal + b.normal + c.normal
                #expect(simd_dot(faceNormal, averageNormal) > 0, "\(mesh) triangle at indices[\(i)...]")
            }
            i += 3
        }
        #expect(nonDegenerateCount > 0, "\(mesh) had no non-degenerate triangles to check")
    }

    @Test func buildingIsDeterministic() {
        let a = MeshBuilder.build(.sphere), b = MeshBuilder.build(.sphere)
        #expect(a.vertices == b.vertices)
        #expect(a.indices == b.indices)
    }

    /// The Swift struct and the MSL struct must agree, or the vertex stage reads garbage.
    ///
    /// The brief expected a stride of 64 (12 + 12 + 16 + 8 + 16, padded to 16), which assumes
    /// `SIMD3<Float>` occupies 12 bytes the way `float3`/`packed_float3` can in MSL. In Swift,
    /// `MemoryLayout<SIMD3<Float>>.size/.stride/.alignment` are all 16 — a `SIMD3<Float>` field
    /// always consumes a full 16 bytes, regardless of struct field order (verified: reordering
    /// fields by descending alignment still produces 80). So the two `SIMD3<Float>` fields
    /// (position, normal) cost 16 bytes each instead of 12, giving 16+16+16+8+16 = 72, rounded
    /// up to the struct's 16-byte alignment = 80. Reaching 64 would require replacing
    /// `position`/`normal` with a tightly packed 12-byte type, which breaks the public API this
    /// task specifies (call sites and other tests use `simd_length`/`simd_dot` on
    /// `SIMD3<Float>` directly). Asserting the real, measured value here; see the M7 Task 10
    /// report for this as a flagged concern for whoever writes `MaterialPreviewCodegen`
    /// (Task 8) — the generated MSL struct's field order/padding must reproduce 80 bytes to
    /// match, e.g. by inserting explicit padding fields rather than relying on `float3`'s
    /// natural MSL alignment.
    @Test func theSwiftLayoutMatchesTheGeneratedMslStruct() {
        #expect(MemoryLayout<MeshVertex>.stride == 80)
    }
}
