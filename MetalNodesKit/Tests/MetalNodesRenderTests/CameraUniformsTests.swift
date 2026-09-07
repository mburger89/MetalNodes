import Testing
import simd
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct CameraUniformsTests {
    @Test func theDefaultCameraLooksAtTheOrigin() {
        let c = OrbitCamera.default
        let u = c.uniforms(aspect: 1)
        // Eye is `distance` from the origin.
        #expect(abs(simd_length(u.cameraPosition) - c.distance) < 1e-4)
        // The origin projects near the centre of clip space.
        let clip = u.viewToProjection * (u.worldToView * SIMD4<Float>(0, 0, 0, 1))
        #expect(abs(clip.x) < 1e-4)
        #expect(abs(clip.y) < 1e-4)
        #expect(clip.w > 0)
    }

    @Test func orbitingWrapsAzimuthAndClampsElevation() {
        var c = OrbitCamera.default
        c.orbit(dx: 100, dy: 100)
        #expect(c.elevation <= Float.pi / 2 - 0.01)
        c.orbit(dx: 0, dy: -1000)
        #expect(c.elevation >= -Float.pi / 2 + 0.01)
    }

    @Test func dollyingStaysPositiveAndBounded() {
        var c = OrbitCamera.default
        c.dolly(-1000)
        #expect(c.distance >= 0.5)
        c.dolly(1000)
        #expect(c.distance <= 20)
    }

    @Test func normalToWorldIsTheInverseTransposeOfTheUpperLeft() {
        let u = OrbitCamera.default.uniforms(aspect: 1.7)
        // With an identity model transform the normal matrix is identity too.
        let n = u.normalToWorld
        #expect(abs(n.columns.0.x - 1) < 1e-5)
        #expect(abs(n.columns.1.y - 1) < 1e-5)
        #expect(abs(n.columns.2.z - 1) < 1e-5)
    }

    @Test func aspectWidensTheHorizontalFieldOfView() {
        let square = OrbitCamera.default.uniforms(aspect: 1)
        let wide = OrbitCamera.default.uniforms(aspect: 2)
        #expect(wide.viewToProjection.columns.0.x < square.viewToProjection.columns.0.x)
        #expect(abs(wide.viewToProjection.columns.1.y - square.viewToProjection.columns.1.y) < 1e-5)
    }

    /// This branch predates `MaterialPreviewCodegen` (Task 8). The MSL-side half of this
    /// assertion — that `MaterialPreviewCodegen.cameraStruct` contains `float3x3 normalToWorld;`
    /// — is added when that type lands.
    @Test func theSwiftLayoutMatchesTheGeneratedMslStruct() {
        // float4x4 ×3 (192) + float3x3 (48) + float3 (16) = 256.
        #expect(MemoryLayout<CameraUniforms>.stride == 256)
    }
}
