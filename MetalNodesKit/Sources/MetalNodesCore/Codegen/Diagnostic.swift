import Foundation

public struct Diagnostic: Sendable, Hashable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var node: NodeID?
    public var socket: String?
    /// The 1-based line of the user's own text this diagnostic points at — an Expression's formula
    /// or a Custom MSL definition body — or `nil` when it does not resolve to user-authored text
    /// (spec §24.4). Set by `EditorModel` from `LineMap.userLine(forLine:)` after a compile failure.
    public var userLine: Int?
    /// The Custom MSL definition whose body this diagnostic is inside, or `nil`. Lets the code
    /// editor (Task 17) list only the open definition's own errors.
    public var definition: GroupID?

    public init(_ severity: Severity = .error, _ message: String, node: NodeID? = nil, socket: String? = nil,
                userLine: Int? = nil, definition: GroupID? = nil) {
        self.severity = severity; self.message = message; self.node = node; self.socket = socket
        self.userLine = userLine; self.definition = definition
    }
}

public enum GenerationError: Error, Equatable {
    case invalid([Diagnostic])
}

public enum StitchableKind: String, Sendable, CaseIterable, Codable {
    case colorEffect, distortionEffect, layerEffect
}

/// What the generated program is for.
public enum OutputTarget: Sendable, Hashable, Codable {
    case fragment
    case stitchable(StitchableKind)
    case realityKit

    public static let all: [OutputTarget] = [.fragment, .stitchable(.colorEffect), .stitchable(.distortionEffect), .stitchable(.layerEffect), .realityKit]

    public var title: String {
        switch self {
        case .fragment: "Fragment (preview)"
        case .stitchable(.colorEffect): "SwiftUI Color Effect"
        case .stitchable(.distortionEffect): "SwiftUI Distortion Effect"
        case .stitchable(.layerEffect): "SwiftUI Layer Effect"
        case .realityKit: "RealityKit Material"
        }
    }

    public var stitchableKind: StitchableKind? {
        if case .stitchable(let k) = self { return k } else { return nil }
    }
}
