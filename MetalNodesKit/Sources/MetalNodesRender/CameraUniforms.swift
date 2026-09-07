import Foundation
import simd
import MetalNodesCore

/// Matches `MaterialPreviewCodegen.cameraStruct` field for field; bound at buffer index 1 in both
/// stages (spec §23.5). Camera data lives in its own buffer so `SocketType` never needs a matrix
/// case and no node can reach it.
public struct CameraUniforms: Equatable, Sendable {
    public var modelToWorld: float4x4
    public var worldToView: float4x4
    public var viewToProjection: float4x4
    public var normalToWorld: float3x3
    public var cameraPosition: SIMD3<Float>
}

public extension OrbitCamera {
    var eye: SIMD3<Float> {
        SIMD3(distance * cos(elevation) * sin(azimuth),
              distance * sin(elevation),
              distance * cos(elevation) * cos(azimuth))
    }

    func uniforms(aspect: Float, fieldOfView: Float = .pi / 4,
                  near: Float = 0.05, far: Float = 100) -> CameraUniforms {
        let model = matrix_identity_float4x4
        let view = OrbitCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let projection = OrbitCamera.perspective(fovY: fieldOfView, aspect: max(aspect, 0.01), near: near, far: far)
        // Inverse transpose of the model's upper-left 3×3; identity here, but written out so a
        // non-identity model transform stays correct if one is ever introduced.
        let upper = float3x3(model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz)
        return CameraUniforms(modelToWorld: model, worldToView: view, viewToProjection: projection,
                              normalToWorld: upper.inverse.transpose, cameraPosition: eye)
    }

    internal static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0),
                                  SIMD4(s.y, u.y, -f.y, 0),
                                  SIMD4(s.z, u.z, -f.z, 0),
                                  SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Metal's clip space: z in 0…1, right-handed view space.
    internal static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return float4x4(columns: (SIMD4(x, 0, 0, 0),
                                  SIMD4(0, y, 0, 0),
                                  SIMD4(0, 0, z, -1),
                                  SIMD4(0, 0, z * near, 0)))
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
