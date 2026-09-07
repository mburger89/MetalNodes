import Foundation

/// Which shape the 3D preview draws (spec §23.5). View state, not document state — it lives in
/// Core because `EditorViewState` stores it and Core cannot import Render.
public enum PreviewMesh: String, Codable, Sendable, CaseIterable, Hashable {
    case sphere, cube, plane, torus

    public var title: String {
        switch self {
        case .sphere: "Sphere"
        case .cube: "Cube"
        case .plane: "Plane"
        case .torus: "Torus"
        }
    }
}

/// The 3D preview's camera: an angle pair and a distance, orbiting the origin (spec §23.5).
/// View state — persisted with the document, never undone. The matrices it produces live in
/// `MetalNodesRender`, because `CameraUniforms` is a GPU layout.
public struct OrbitCamera: Codable, Sendable, Hashable {
    public var azimuth: Float
    public var elevation: Float
    public var distance: Float

    public static let `default` = OrbitCamera(azimuth: 0.6, elevation: 0.3, distance: 3.0)

    public init(azimuth: Float = 0.6, elevation: Float = 0.3, distance: Float = 3.0) {
        self.azimuth = azimuth; self.elevation = elevation; self.distance = distance
    }

    /// A drag in points. Elevation clamps just short of the poles so the up vector never degenerates.
    public mutating func orbit(dx: Float, dy: Float) {
        azimuth += dx * 0.01
        elevation = min(max(elevation + dy * 0.01, -.pi / 2 + 0.01), .pi / 2 - 0.01)
    }

    /// Scroll or pinch. Bounded so the model can neither be lost nor turned inside out.
    public mutating func dolly(_ delta: Float) {
        distance = min(max(distance - delta * 0.01, 0.5), 20)
    }
}
