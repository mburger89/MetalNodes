import Foundation

/// Strongly-typed UUID wrappers. Each encodes as a bare UUID string so the
/// JSON stays readable and the types can never be mixed up at compile time.
public protocol EntityID: Hashable, Codable, Sendable, CustomStringConvertible {
    var raw: UUID { get }
    init(raw: UUID)
}

public extension EntityID {
    init() { self.init(raw: UUID()) }
    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(UUID.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    var description: String { raw.uuidString }
}

public struct NodeID: EntityID   { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct GroupID: EntityID  { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct StickyID: EntityID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct FrameID: EntityID  { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct AssetID: EntityID  { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

/// Parameter and socket-value keys on a node instance. Socket names and
/// parameter names share one namespace per node definition (Task 5 enforces uniqueness).
public typealias ParamID = String
