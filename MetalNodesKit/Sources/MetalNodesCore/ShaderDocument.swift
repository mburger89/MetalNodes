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

public struct DocumentSettings: Sendable, Hashable {
    public var previewSize: CGSize = CGSize(width: 512, height: 512)
    public var timeMode: TimeMode = .wallClock
    /// Metal fast-math for every compiled shader (spec §18.1). Part of the pipeline cache key.
    public var fastMath: Bool = true
    /// What the document exports as (spec §19). Fragment preview is always available regardless.
    public var target: OutputTarget = .fragment
    /// The name given to the exported SwiftUI stitchable function / Swift symbol.
    public var exportName: String = "metalNodesShader"
    public init() {}
}

extension DocumentSettings: Codable {
    private enum Keys: String, CodingKey { case previewSize, timeMode, fastMath, target, exportName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        previewSize = try c.decodeIfPresent(CGSize.self, forKey: .previewSize) ?? CGSize(width: 512, height: 512)
        timeMode = try c.decodeIfPresent(TimeMode.self, forKey: .timeMode) ?? .wallClock
        fastMath = try c.decodeIfPresent(Bool.self, forKey: .fastMath) ?? true
        target = try c.decodeIfPresent(OutputTarget.self, forKey: .target) ?? .fragment
        exportName = try c.decodeIfPresent(String.self, forKey: .exportName) ?? "metalNodesShader"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(previewSize, forKey: .previewSize)
        try c.encode(timeMode, forKey: .timeMode)
        try c.encode(fastMath, forKey: .fastMath)
        try c.encode(target, forKey: .target)
        try c.encode(exportName, forKey: .exportName)
    }
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
