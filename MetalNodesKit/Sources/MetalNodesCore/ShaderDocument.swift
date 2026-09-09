import Foundation
import CoreGraphics

/// What a definition's function is built from (spec §24.3): a subgraph, as every definition was
/// before M8, or hand-written MSL. Both emit one function, called once per instance.
public enum DefinitionBody: Sendable, Hashable {
    case graph(Graph)
    case msl(String)
}

/// A reusable function: one definition, many `NodeKind.group` instances (spec §3, §4).
public struct GroupDefinition: Sendable, Hashable, Identifiable {
    public let id: GroupID
    public var name: String
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    /// What the function is made of (spec §24.3). Assigning this is the only way to change a
    /// definition from a subgraph to hand-written code or back.
    public var body: DefinitionBody
    public var accent: DraculaAccent

    public init(id: GroupID = GroupID(), name: String, inputs: [SocketDecl] = [], outputs: [SocketDecl] = [],
                graph: Graph = Graph(), accent: DraculaAccent = .purple) {
        self.id = id; self.name = name; self.inputs = inputs; self.outputs = outputs
        self.body = .graph(graph); self.accent = accent
    }

    /// The definition's subgraph — the whole story for a `.graph` body, and an empty graph for a
    /// `.msl` one, so every call site that only reads a definition's nodes keeps working.
    ///
    /// The setter deliberately does **nothing** for a `.msl` body. Writing a graph into a text
    /// definition would replace the user's code with a subgraph and lose it, which is the worst
    /// thing this milestone could do; a caller that really means to change what a definition is
    /// made of assigns `body`. For a `.graph` body it is exactly the stored property it replaced,
    /// so `def.graph.nodes[id] = n` still reads-modifies-writes the subgraph in place.
    public var graph: Graph {
        get { if case .graph(let g) = body { return g } else { return Graph() } }
        set { if case .graph = body { body = .graph(newValue) } }
    }
}

/// Self-describing on the wire — `{"kind":"graph","graph":{…}}` or `{"kind":"msl","msl":"…"}` —
/// so a later build can add a third kind without moving what is already written, and this build
/// can tell that it has met one (spec §24.3).
extension DefinitionBody: Codable {
    private enum Keys: String, CodingKey { case kind, graph, msl }
    private enum Kind: String, Codable { case graph, msl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // An unrecognised kind is a body a newer build wrote, and it **throws**. Unlike §23.2's
        // unknown `target` — where degrading to a default loses a preference — degrading here
        // would hand back an empty definition, and the next save would rewrite someone's source
        // code as `{"kind":"graph","graph":{}}`, unrecoverably. Failing leaves the bytes on disk
        // intact for a build that understands them. `currentFormatVersion` should stop such a
        // document at the door anyway (`ShaderPackage.VersionProbe`); this is the loud backstop.
        switch try c.decode(Kind.self, forKey: .kind) {
        case .msl: self = .msl(try c.decodeIfPresent(String.self, forKey: .msl) ?? "")
        case .graph: self = .graph(try c.decodeIfPresent(Graph.self, forKey: .graph) ?? Graph())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .graph(let g): try c.encode(Kind.graph, forKey: .kind); try c.encode(g, forKey: .graph)
        case .msl(let text): try c.encode(Kind.msl, forKey: .kind); try c.encode(text, forKey: .msl)
        }
    }
}

extension GroupDefinition: Codable {
    private enum Keys: String, CodingKey { case id, name, inputs, outputs, body, graph, accent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(GroupID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        inputs = try c.decodeIfPresent([SocketDecl].self, forKey: .inputs) ?? []
        outputs = try c.decodeIfPresent([SocketDecl].self, forKey: .outputs) ?? []
        accent = try c.decodeIfPresent(DraculaAccent.self, forKey: .accent) ?? .purple
        // M8 writes `body`; every document written before it wrote `graph` (spec §24.3). Both
        // shapes must open, and a pre-M8 definition must come back as exactly the graph it was.
        if let b = try c.decodeIfPresent(DefinitionBody.self, forKey: .body) {
            body = b
        } else {
            body = .graph(try c.decodeIfPresent(Graph.self, forKey: .graph) ?? Graph())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(body, forKey: .body)
        try c.encode(accent, forKey: .accent)
    }
}

public enum TimeMode: String, Codable, Sendable { case wallClock, fixedRate }

/// One imported image in the package's manifest (spec §21.2). The bytes live in
/// `textures/<AssetID>.<fileExtension>`; this is everything the editor and codegen need without them.
public struct AssetInfo: Sendable, Hashable, Codable {
    public var name: String
    public var pixelSize: CGSize
    public var fileExtension: String

    public init(name: String, pixelSize: CGSize, fileExtension: String) {
        self.name = name; self.pixelSize = pixelSize; self.fileExtension = fileExtension
    }

    private enum Keys: String, CodingKey { case name, pixelSize, fileExtension }

    /// `fileExtension` becomes half of `ShaderPackage.fileName(for:info:)`'s filename (spec §21.1):
    /// a hand-edited or migrated document that smuggled a path separator into it must not be able
    /// to steer that filename outside `textures/`. Stripped to letters and digits only, so
    /// `"png/../y"` reads as `"pngy"` and an all-separator value falls back to `"bin"`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        pixelSize = try c.decode(CGSize.self, forKey: .pixelSize)
        let raw = try c.decode(String.self, forKey: .fileExtension)
        let sanitised = raw.filter { $0.isLetter || $0.isNumber }
        fileExtension = sanitised.isEmpty ? "bin" : sanitised
    }
}

public struct DocumentSettings: Sendable, Hashable {
    public var previewSize: CGSize = CGSize(width: 512, height: 512)
    public var timeMode: TimeMode = .wallClock
    /// Metal fast-math for every compiled shader (spec §18.1). Part of the pipeline cache key.
    public var fastMath: Bool = true
    /// What the document exports as (spec §19). Fragment preview is always available regardless.
    public var target: OutputTarget = .fragment
    /// The `CustomMaterial.LightingModel` the RealityKit target exports and the 3D preview
    /// approximates (spec §23.8). Ignored by every other target.
    public var lightingModel: MaterialLightingModel = .lit
    /// The name given to the exported SwiftUI stitchable function / Swift symbol.
    public var exportName: String = "metalNodesShader"
    /// The imported images this document references (spec §21.2). Never auto-pruned.
    public var assets: [AssetID: AssetInfo] = [:]
    /// Parameters that animate from Swift rather than baking into the exported `.metal`
    /// (spec §24.6). Ordered: index 0 is `custom_parameter().x`. At most four — a `CustomMaterial`
    /// exposes exactly one `float4`.
    public var liveParameters: [ParamPath] = []
    /// The loop this document plays and records (spec §26.2). Optional in the file: a document
    /// written before M10 opens with `Timeline()`.
    public var timeline = Timeline()
    public init() {}
}

extension DocumentSettings: Codable {
    private enum Keys: String, CodingKey { case previewSize, timeMode, fastMath, target, exportName, assets, lightingModel, liveParameters, timeline }

    /// A dictionary keyed by a struct encodes as a flat `[key, value, …]` array, which neither
    /// diffs nor reads well — so `assets` is written as an array of these, sorted by id.
    private struct AssetEntry: Codable {
        let id: AssetID
        let info: AssetInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        previewSize = try c.decodeIfPresent(CGSize.self, forKey: .previewSize) ?? CGSize(width: 512, height: 512)
        timeMode = try c.decodeIfPresent(TimeMode.self, forKey: .timeMode) ?? .wallClock
        fastMath = try c.decodeIfPresent(Bool.self, forKey: .fastMath) ?? true
        // A document written by a newer build may name a target this build has no case for.
        // `decodeIfPresent` *throws* on an unknown case, which would fail the whole settings
        // object and so the whole document; `try?` degrades to Fragment instead (spec §23.2).
        // Since SE-0230, `try?` on an already-Optional-returning expression flattens the result
        // itself, so no further `.flatMap { $0 }` is needed.
        target = (try? c.decodeIfPresent(OutputTarget.self, forKey: .target)) ?? .fragment
        lightingModel = (try? c.decodeIfPresent(MaterialLightingModel.self, forKey: .lightingModel)) ?? .lit
        exportName = try c.decodeIfPresent(String.self, forKey: .exportName) ?? "metalNodesShader"
        let entries = try c.decodeIfPresent([AssetEntry].self, forKey: .assets) ?? []
        assets = Dictionary(entries.map { ($0.id, $0.info) }, uniquingKeysWith: { $1 })
        liveParameters = try c.decodeIfPresent([ParamPath].self, forKey: .liveParameters) ?? []
        timeline = try c.decodeIfPresent(Timeline.self, forKey: .timeline) ?? Timeline()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(previewSize, forKey: .previewSize)
        try c.encode(timeMode, forKey: .timeMode)
        try c.encode(fastMath, forKey: .fastMath)
        try c.encode(target, forKey: .target)
        try c.encode(lightingModel, forKey: .lightingModel)
        try c.encode(exportName, forKey: .exportName)
        try c.encode(assets.map { AssetEntry(id: $0.key, info: $0.value) }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .assets)
        try c.encode(liveParameters, forKey: .liveParameters)
        try c.encode(timeline, forKey: .timeline)
    }
}

public struct ShaderDocument: Sendable, Hashable {
    /// 2 since M8. Every change before it was additive — a new key an older build's
    /// `decodeIfPresent` simply skipped — so the number never had to move. M8 writes a
    /// definition's `body` and no longer writes `graph`, which an M0–M7 build cannot decode at
    /// all, so the version now says so and those builds report "saved by a newer version of
    /// MetalNodes" instead of a decoding failure (`ShaderPackage.VersionProbe`, spec §24.3).
    public static let currentFormatVersion = 2

    /// The version this document was *read* as; what is written is always
    /// `currentFormatVersion`, because that is the format the bytes are in.
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

    /// The pseudo-nodes, which only a `.graph` body has: `nil` for a `.msl` one, whose inputs and
    /// outputs are the declared sockets alone (spec §24.3).
    var inputNode: NodeID? { graph.nodes.values.first { $0.kind == .groupInput }?.id }
    var outputNode: NodeID? { graph.nodes.values.first { $0.kind == .groupOutput }?.id }

    /// A deep copy under a fresh `GroupID` and the given name: same inputs/outputs/accent, but
    /// every inner `NodeID` reminted (both ends of every wire rewritten to match) so the copy's
    /// nodes never collide with the original's document-wide (controller ruling R12). Shared by
    /// Make Unique (spec §20.6) and clipboard import (spec §20.7) — nested `.group` references
    /// inside the copied graph are left pointing at whatever they pointed at; a caller that also
    /// needs to retarget those (e.g. because the referenced definition is itself being imported
    /// under a new id) does so as a separate pass.
    ///
    /// A `.msl` body has no ids to remint, so the copy carries the text verbatim.
    func duplicate(name: String) -> GroupDefinition {
        var copy = GroupDefinition(name: name, inputs: inputs, outputs: outputs, accent: accent)
        if case .msl(let text) = body {
            copy.body = .msl(text)
            return copy
        }
        var map: [NodeID: NodeID] = [:]
        for n in graph.nodes.values {
            let id = NodeID(); map[n.id] = id
            copy.graph.nodes[id] = NodeInstance(id: id, kind: n.kind, position: n.position,
                                                 params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        // A wire whose either end names a node the graph does not hold is dangling: drop it rather
        // than trap — a decoded or hand-built definition can carry one.
        for (to, from) in graph.inputs {
            guard let f = map[from.node], let t = map[to.node] else { continue }
            copy.graph.connect(SocketRef(f, from.socket), to: SocketRef(t, to.socket))
        }
        return copy
    }

    /// Identity of the definition's content (spec §20.7): name, sockets, accent and body, ids included.
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
    /// `_modify` yields the storage, so `doc[path].nodes[id]?.position = p` reaches the graph
    /// through one access rather than the get→copy→set an assignment would spell out. The root is
    /// still yielded in place; a definition's graph now lives inside `body`, so it is yielded
    /// through `GroupDefinition.graph` and costs one copy of the node table per mutation — next to
    /// nothing beside the document copy every `DocumentChange` already makes.
    ///
    /// A `.msl` definition reads as an empty graph and *ignores* every write, through both paths —
    /// see `GroupDefinition.graph`. Silently dropping the write is deliberate: this subscript is
    /// the editor's channel for canvas edits, and against a text body the alternative is either
    /// replacing the user's code with a graph or trapping in the middle of a gesture.
    subscript(path: GraphPath) -> Graph {
        get { graph(at: path) ?? Graph() }
        _modify {
            switch path {
            case .root:
                yield &root
            case .definition(let id):
                precondition(definitions[id] != nil, "no definition \(id)")
                yield &definitions[id]!.graph
            }
        }
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
        definitions = try .uniqueOrThrow(try c.decode([GroupDefinition].self, forKey: .definitions).map { ($0.id, $0) },
                                         codingPath: c.codingPath + [Keys.definitions]) { "duplicate definition id \($0.raw.uuidString)" }
        settings = try c.decode(DocumentSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        // Always the current version, never the one the document was read as: these bytes carry
        // `body`, so a document migrated from M0–M7 and saved is an M8 document and must announce
        // itself as one — otherwise the build that wrote the original still cannot read it back
        // and reports a decoding failure rather than "saved by a newer version".
        try c.encode(ShaderDocument.currentFormatVersion, forKey: .formatVersion)
        try c.encode(root, forKey: .root)
        try c.encode(definitions.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .definitions)
        try c.encode(settings, forKey: .settings)
    }
}
