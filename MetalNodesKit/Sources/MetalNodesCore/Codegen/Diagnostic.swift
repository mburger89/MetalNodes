import Foundation

public struct Diagnostic: Sendable, Hashable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var node: NodeID?
    public var socket: String?

    public init(_ severity: Severity = .error, _ message: String, node: NodeID? = nil, socket: String? = nil) {
        self.severity = severity; self.message = message; self.node = node; self.socket = socket
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

    public static let all: [OutputTarget] = [.fragment, .stitchable(.colorEffect), .stitchable(.distortionEffect), .stitchable(.layerEffect)]

    public var title: String {
        switch self {
        case .fragment: "Fragment (preview)"
        case .stitchable(.colorEffect): "SwiftUI Color Effect"
        case .stitchable(.distortionEffect): "SwiftUI Distortion Effect"
        case .stitchable(.layerEffect): "SwiftUI Layer Effect"
        }
    }

    public var stitchableKind: StitchableKind? {
        if case .stitchable(let k) = self { return k } else { return nil }
    }
}
