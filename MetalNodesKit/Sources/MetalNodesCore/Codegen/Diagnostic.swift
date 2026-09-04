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

/// What the generated program is for. Only `.fragment` is implemented before M3.
public enum OutputTarget: Sendable, Hashable {
    case fragment
    case stitchable(StitchableKind)
}
