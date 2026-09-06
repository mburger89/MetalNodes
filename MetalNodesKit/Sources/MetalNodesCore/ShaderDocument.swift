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

public extension GroupDefinition {
    /// A fresh definition with its two pseudo-nodes (spec §20.2): input at (0, 0), output at (600, 0).
    static func make(name: String, accent: DraculaAccent = .purple) -> GroupDefinition {
        var d = GroupDefinition(name: name, accent: accent)
        let i = NodeInstance(kind: .groupInput, position: CGPoint(x: 0, y: 0))
        let o = NodeInstance(kind: .groupOutput, position: CGPoint(x: 600, y: 0))
        d.graph.nodes[i.id] = i
        d.graph.nodes[o.id] = o
        return d
    }

    var inputNode: NodeID? { graph.nodes.values.first { $0.kind == .groupInput }?.id }
    var outputNode: NodeID? { graph.nodes.values.first { $0.kind == .groupOutput }?.id }

    /// A deep copy under a fresh `GroupID` and the given name: same inputs/outputs/accent, but
    /// every inner `NodeID` reminted (both ends of every wire rewritten to match) so the copy's
    /// nodes never collide with the original's document-wide (controller ruling R12). Shared by
    /// Make Unique (spec §20.6) and clipboard import (spec §20.7) — nested `.group` references
    /// inside the copied graph are left pointing at whatever they pointed at; a caller that also
    /// needs to retarget those (e.g. because the referenced definition is itself being imported
    /// under a new id) does so as a separate pass.
    func duplicate(name: String) -> GroupDefinition {
        var copy = GroupDefinition(name: name, inputs: inputs, outputs: outputs, accent: accent)
        var map: [NodeID: NodeID] = [:]
        for n in graph.nodes.values {
            let id = NodeID(); map[n.id] = id
            copy.graph.nodes[id] = NodeInstance(id: id, kind: n.kind, position: n.position,
                                                 params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        for (to, from) in graph.inputs {
            copy.graph.connect(SocketRef(map[from.node]!, from.socket), to: SocketRef(map[to.node]!, to.socket))
        }
        return copy
    }

    /// Identity of the definition's content (spec §20.7): name, sockets, accent and graph, ids included.
    var contentHash: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(self)) ?? Data()
        return ContentHash.fnv1a(data)
    }
}

public extension ShaderDocument {
    func graph(at path: GraphPath) -> Graph? {
        switch path {
        case .root: root
        case .definition(let id): definitions[id]?.graph
        }
    }

    /// Reads/mutates the graph at `path`. Writing to a missing definition is a programmer error.
    subscript(path: GraphPath) -> Graph {
        get { graph(at: path) ?? Graph() }
        set {
            switch path {
            case .root: root = newValue
            case .definition(let id):
                precondition(definitions[id] != nil, "no definition \(id)")
                definitions[id]!.graph = newValue
            }
        }
    }

    /// Ids are unique document-wide: find an instance in any graph.
    func node(_ id: NodeID) -> (node: NodeInstance, path: GraphPath)? {
        if let n = root.nodes[id] { return (n, .root) }
        for d in definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            if let n = d.graph.nodes[id] { return (n, .definition(d.id)) }
        }
        return nil
    }
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
