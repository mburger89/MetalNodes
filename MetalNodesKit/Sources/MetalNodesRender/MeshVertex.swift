import Foundation
import simd

/// One preview mesh vertex. The field order and padding must match
/// `MaterialPreviewCodegen.meshVertexStruct` (Task 8, not yet written); `MeshBuilderTests`
/// asserts the stride.
///
/// `MemoryLayout<MeshVertex>.stride` is 80, not the 64 a naive byte count suggests: Swift's
/// `SIMD3<Float>` always has size/stride/alignment 16 (never 12), so `position` and `normal`
/// each cost a full 16 bytes regardless of field order. 16+16+16+8+16 = 72, rounded up to the
/// struct's 16-byte alignment = 80. See `MeshBuilderTests.theSwiftLayoutMatchesTheGeneratedMslStruct`
/// for the full reasoning; the generated MSL struct must reproduce 80 bytes to match.
///
/// `tangent.w` carries handedness: the bitangent is `cross(normal, tangent.xyz) * tangent.w`.
public struct MeshVertex: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var tangent: SIMD4<Float>
    public var uv: SIMD2<Float>
    public var color: SIMD4<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, tangent: SIMD4<Float>,
                uv: SIMD2<Float>, color: SIMD4<Float> = .init(1, 1, 1, 1)) {
        self.position = position; self.normal = normal; self.tangent = tangent
        self.uv = uv; self.color = color
    }
}
