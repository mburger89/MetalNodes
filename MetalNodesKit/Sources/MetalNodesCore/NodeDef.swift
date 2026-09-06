import Foundation

public struct SocketDecl: Sendable, Hashable, Codable {
    public var name: String
    public var label: String
    public var type: TypeRef
    public var `default`: SocketDefault
    /// Slider range for the unwired-input fallback control. `nil` uses the control's own default.
    public var range: ClosedRange<Float>?

    public init(name: String, label: String? = nil, type: TypeRef, default: SocketDefault = .required,
                range: ClosedRange<Float>? = nil) {
        self.name = name
        self.label = label ?? name.capitalized
        self.type = type
        self.default = `default`
        self.range = range
    }
}

public enum ParamKind: Sendable, Hashable {
    case value(SocketType, range: ClosedRange<Float>?)
    case enumeration([String])
    case asset
}

public struct ParamDecl: Sendable, Hashable {
    public var name: String
    public var label: String
    public var kind: ParamKind
    public var defaultValue: ParamValue
    /// False hides the control from the node body; the inspector still shows it (spec §19.5).
    public var showsInBody: Bool

    public init(name: String, label: String? = nil, kind: ParamKind, defaultValue: ParamValue, showsInBody: Bool = true) {
        self.name = name
        self.label = label ?? name.capitalized
        self.kind = kind
        self.defaultValue = defaultValue
        self.showsInBody = showsInBody
    }
}

/// How the canvas draws a node (spec §19.5).
public enum NodeStyle: Sendable, Hashable {
    case standard
    /// A 24 × 24 dot with one input on the left and one output on the right (Reroute).
    case dot
}

public enum NodeCategory: String, Codable, Sendable, CaseIterable {
    case input, math, vector, sdf, noise, color, utility, group, output
}

/// Everything a custom emitter needs: resolved MSL expressions for each
/// input, variable names for each output, uniform expressions for value
/// params, chosen cases for enum params, and resolved types for generics.
public struct EmitContext: Sendable {
    public var inputs: [String: String]
    public var outputs: [String: String]
    public var params: [String: String]
    public var enums: [String: String]
    public var types: [String: SocketType]
    /// The four system values (`uv`, `time`, `resolution`, `mouse`), spelled for the target program.
    public var sys: [String: String]
    /// The complete texture-sample expression for this node in this target (spec §21.2) — what
    /// `{tex.sample}` substitutes to. Empty for every node that does not sample a texture.
    public var texture: String

    public init(inputs: [String: String], outputs: [String: String], params: [String: String],
                enums: [String: String], types: [String: SocketType], sys: [String: String] = [:],
                texture: String = "") {
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.enums = enums; self.types = types; self.sys = sys; self.texture = texture
    }
}

public enum NodeBody: Sendable {
    /// One template using `{in.x}`, `{out.x}`, `{param.x}`, `{type.T}` placeholders.
    case template(String)
    /// One template per case of the named enum parameter.
    case variants(param: String, [String: String])
    /// Escape hatch: produce statement lines directly.
    case custom(@Sendable (EmitContext) -> [String])
}

/// A node *type*. Pure data — adding a node to the library is adding one of these.
public struct NodeDef: Sendable, Identifiable {
    public let id: String
    public var title: String
    public var category: NodeCategory
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    public var params: [ParamDecl]
    public var generics: [String: [SocketType]]
    public var requires: [String]
    public var body: NodeBody
    public var style: NodeStyle

    public init(id: String, title: String, category: NodeCategory,
                inputs: [SocketDecl] = [], outputs: [SocketDecl] = [], params: [ParamDecl] = [],
                generics: [String: [SocketType]] = [:], requires: [String] = [], body: NodeBody,
                style: NodeStyle = .standard) {
        self.id = id; self.title = title; self.category = category
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.generics = generics; self.requires = requires; self.body = body; self.style = style
    }

    public func input(named n: String) -> SocketDecl? { inputs.first { $0.name == n } }
    public func output(named n: String) -> SocketDecl? { outputs.first { $0.name == n } }
    public func param(named n: String) -> ParamDecl? { params.first { $0.name == n } }
}
