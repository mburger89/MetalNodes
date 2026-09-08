import Foundation

/// The two shader stages a RealityKit `CustomMaterial` is authored from (spec §23.2). One graph
/// emits both: the surface shader runs per fragment, the geometry modifier per vertex.
public enum MaterialStage: String, Codable, Sendable, CaseIterable, Hashable {
    case surface, geometry

    public static let all: Set<MaterialStage> = [.surface, .geometry]

    /// How the stage names itself in a diagnostic.
    public var title: String {
        switch self {
        case .surface: "surface"
        case .geometry: "geometry"
        }
    }
}

/// `CustomMaterial.LightingModel` (spec §23.2). `.clearcoat` was deferred until the terminal grew
/// the sockets its setters need — see spec §24.7 for the preview's second-lobe approximation of it.
public enum MaterialLightingModel: String, Codable, Sendable, CaseIterable, Hashable {
    case lit, unlit, clearcoat

    public var title: String {
        switch self {
        case .lit: "Lit (PBR)"
        case .unlit: "Unlit"
        case .clearcoat: "Clearcoat"
        }
    }

    /// The `CustomMaterial.LightingModel` case the exported Swift snippet names.
    public var swiftCase: String { ".\(rawValue)" }
}
