import Foundation

/// What a node looks like to layout, wiring, typing and drawing (spec §20.2): a builtin's
/// definition, a group instance's exposed sockets, or a pseudo-node's mirror of its definition.
public struct NodeShape: Sendable, Hashable {
    public var title: String
    public var category: NodeCategory
    public var accent: DraculaAccent?
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    public var params: [ParamDecl]
    public var generics: [String: [SocketType]]
    public var style: NodeStyle
    /// `GroupInput` / `GroupOutput`: no params, no viewer badge, not deletable.
    public var isPseudo: Bool

    public init(title: String, category: NodeCategory, accent: DraculaAccent? = nil,
                inputs: [SocketDecl] = [], outputs: [SocketDecl] = [], params: [ParamDecl] = [],
                generics: [String: [SocketType]] = [:], style: NodeStyle = .standard, isPseudo: Bool = false) {
        self.title = title; self.category = category; self.accent = accent
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.generics = generics; self.style = style; self.isPseudo = isPseudo
    }

    public init(def: NodeDef) {
        self.init(title: def.title, category: def.category, inputs: def.inputs, outputs: def.outputs,
                  params: def.params, generics: def.generics, style: def.style)
    }

    public func input(named n: String) -> SocketDecl? { inputs.first { $0.name == n } }
    public func output(named n: String) -> SocketDecl? { outputs.first { $0.name == n } }
    public func param(named n: String) -> ParamDecl? { params.first { $0.name == n } }
}

public extension ShaderDocument {
    /// The shape of `node` as it appears in the graph at `path`. `nil` for an unknown builtin,
    /// a dangling instance, or a pseudo-node outside a definition.
    func shape(of node: NodeInstance, in path: GraphPath, registry: NodeRegistry) -> NodeShape? {
        switch node.kind {
        case .builtin(let id):
            return registry[id].map(NodeShape.init(def:))
        case .group(let gid):
            guard let d = definitions[gid] else { return nil }
            return NodeShape(title: d.name, category: .group, accent: d.accent, inputs: d.inputs, outputs: d.outputs)
        case .groupInput:
            guard case .definition(let gid) = path, let d = definitions[gid] else { return nil }
            return NodeShape(title: "Group Input", category: .group, accent: d.accent, outputs: d.inputs, isPseudo: true)
        case .groupOutput:
            guard case .definition(let gid) = path, let d = definitions[gid] else { return nil }
            return NodeShape(title: "Group Output", category: .group, accent: d.accent, inputs: d.outputs, isPseudo: true)
        }
    }

    func shape(of id: NodeID, registry: NodeRegistry) -> NodeShape? {
        guard let (n, path) = node(id) else { return nil }
        return shape(of: n, in: path, registry: registry)
    }
}
