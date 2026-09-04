import Foundation
import CoreGraphics

/// A reusable function: one definition, many `NodeKind.group` instances (spec §3, §4).
public struct GroupDefinition: Codable, Sendable, Hashable, Identifiable {
    public let id: GroupID
    public var name: String
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    public var graph: Graph
    public var accent: DraculaAccent

    public init(id: GroupID = GroupID(), name: String, inputs: [SocketDecl] = [], outputs: [SocketDecl] = [],
                graph: Graph = Graph(), accent: DraculaAccent = .purple) {
        self.id = id; self.name = name; self.inputs = inputs; self.outputs = outputs
        self.graph = graph; self.accent = accent
    }
}

public enum TimeMode: String, Codable, Sendable { case wallClock, fixedRate }

public struct DocumentSettings: Codable, Sendable, Hashable {
    public var previewSize: CGSize = CGSize(width: 512, height: 512)
    public var timeMode: TimeMode = .wallClock
    public init() {}
}

public struct ShaderDocument: Sendable, Hashable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = ShaderDocument.currentFormatVersion
    public var root: Graph = Graph()
    public var definitions: [GroupID: GroupDefinition] = [:]
    public var settings: DocumentSettings = DocumentSettings()

    public init() {}
}

extension ShaderDocument: Codable {
    private enum Keys: String, CodingKey { case formatVersion, root, definitions, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        root = try c.decode(Graph.self, forKey: .root)
        definitions = Dictionary(uniqueKeysWithValues: try c.decode([GroupDefinition].self, forKey: .definitions).map { ($0.id, $0) })
        settings = try c.decode(DocumentSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(root, forKey: .root)
        try c.encode(definitions.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .definitions)
        try c.encode(settings, forKey: .settings)
    }
}
