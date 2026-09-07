import Foundation
import simd
import MetalNodesCore

/// Procedural preview meshes (spec §23.5). Pure CPU arithmetic — no Metal — so the geometry is
/// unit-testable without a device.
///
/// UVs use the **bottom-left origin** the fragment target uses, so a graph reads the same in the
/// 2D and the 3D preview.
public enum MeshBuilder {
    public static func build(_ mesh: PreviewMesh) -> (vertices: [MeshVertex], indices: [UInt16]) {
        switch mesh {
        case .sphere: sphere(slices: 48, stacks: 24)
        case .cube: cube()
        case .plane: plane(divisions: 16)
        case .torus: torus(major: 48, minor: 24, majorRadius: 0.7, minorRadius: 0.3)
        }
    }

    /// Parameterized by **latitude**, not colatitude: `lat` runs `-π/2…π/2`, south pole to north
    /// pole, so `y = sin(lat)` increases as `j` increases — the same sense in which the plane's
    /// `z` and the torus's `y` (via `sin φ`) increase as `j` increases. `gridIndices` has a single
    /// winding contract (CCW when `j` increases "the way position increases"); colatitude
    /// (`y = cos φ`, *decreasing* as `j` increases) violated that contract and wound every sphere
    /// triangle backwards relative to its own outward normal. See
    /// `MeshBuilderTests.triangleWindingMatchesVertexNormals`.
    private static func sphere(slices: Int, stacks: Int) -> ([MeshVertex], [UInt16]) {
        var v: [MeshVertex] = []
        for j in 0...stacks {
            let lat = Float(j) / Float(stacks) * .pi - .pi / 2   // -π/2…π/2, south to north
            let sinLat = sin(lat), cosLat = cos(lat)
            for i in 0...slices {
                let theta = Float(i) / Float(slices) * 2 * .pi
                let sinTheta = sin(theta), cosTheta = cos(theta)
                let n = SIMD3<Float>(cosLat * cosTheta, sinLat, cosLat * sinTheta)
                // ∂p/∂θ, the direction u increases in — perpendicular to the normal by
                // construction, and already unit length for every θ (no pole degeneracy: the
                // degeneracy at the poles is in ∂p/∂lat, not ∂p/∂θ).
                let tangent = SIMD3<Float>(-sinTheta, 0, cosTheta)
                v.append(MeshVertex(position: n, normal: n,
                                    tangent: SIMD4<Float>(tangent, 1),
                                    uv: SIMD2<Float>(Float(i) / Float(slices),
                                                     Float(j) / Float(stacks))))
            }
        }
        return (v, gridIndices(columns: slices, rows: stacks))
    }

    private static func plane(divisions n: Int) -> ([MeshVertex], [UInt16]) {
        var v: [MeshVertex] = []
        for j in 0...n {
            for i in 0...n {
                let x = Float(i) / Float(n) * 2 - 1
                let z = Float(j) / Float(n) * 2 - 1
                v.append(MeshVertex(position: SIMD3<Float>(x, 0, z),
                                    normal: SIMD3<Float>(0, 1, 0),
                                    tangent: SIMD4<Float>(1, 0, 0, 1),
                                    uv: SIMD2<Float>(Float(i) / Float(n), 1 - Float(j) / Float(n))))
            }
        }
        return (v, gridIndices(columns: n, rows: n))
    }

    private static func torus(major: Int, minor: Int, majorRadius R: Float, minorRadius r: Float) -> ([MeshVertex], [UInt16]) {
        var v: [MeshVertex] = []
        for j in 0...minor {
            let phi = Float(j) / Float(minor) * 2 * .pi
            let cosPhi = cos(phi), sinPhi = sin(phi)
            for i in 0...major {
                let theta = Float(i) / Float(major) * 2 * .pi
                let cosTheta = cos(theta), sinTheta = sin(theta)
                let p = SIMD3<Float>((R + r * cosPhi) * cosTheta, r * sinPhi, (R + r * cosPhi) * sinTheta)
                let n = simd_normalize(SIMD3<Float>(cosPhi * cosTheta, sinPhi, cosPhi * sinTheta))
                let t = simd_normalize(SIMD3<Float>(-sinTheta, 0, cosTheta))
                v.append(MeshVertex(position: p, normal: n, tangent: SIMD4<Float>(t, 1),
                                    uv: SIMD2<Float>(Float(i) / Float(major), 1 - Float(j) / Float(minor))))
            }
        }
        return (v, gridIndices(columns: major, rows: minor))
    }

    /// Six faces, four vertices each — the seams are real, so normals and UVs stay per-face.
    private static func cube() -> ([MeshVertex], [UInt16]) {
        let faces: [(normal: SIMD3<Float>, tangent: SIMD3<Float>)] = [
            (SIMD3( 0,  0,  1), SIMD3(1, 0, 0)), (SIMD3( 0,  0, -1), SIMD3(-1, 0, 0)),
            (SIMD3( 1,  0,  0), SIMD3(0, 0, -1)), (SIMD3(-1,  0,  0), SIMD3(0, 0, 1)),
            (SIMD3( 0,  1,  0), SIMD3(1, 0, 0)),  (SIMD3( 0, -1,  0), SIMD3(1, 0, 0)),
        ]
        var v: [MeshVertex] = []
        var indices: [UInt16] = []
        for face in faces {
            let bitangent = simd_cross(face.normal, face.tangent)
            let base = UInt16(v.count)
            for (dx, dy) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let p = face.normal + face.tangent * dx + bitangent * dy
                v.append(MeshVertex(position: p, normal: face.normal,
                                    tangent: SIMD4<Float>(face.tangent, 1),
                                    uv: SIMD2<Float>((dx + 1) / 2, (dy + 1) / 2)))
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (v, indices)
    }

    /// Two triangles per cell of a `(columns+1) × (rows+1)` vertex grid, counter-clockwise.
    private static func gridIndices(columns: Int, rows: Int) -> [UInt16] {
        var out: [UInt16] = []
        let stride = columns + 1
        for j in 0..<rows {
            for i in 0..<columns {
                let a = UInt16(j * stride + i), b = a + 1
                let c = UInt16((j + 1) * stride + i), d = c + 1
                out += [a, c, b, b, c, d]
            }
        }
        return out
    }
}
