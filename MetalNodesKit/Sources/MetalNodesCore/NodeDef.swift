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

    public init(name: String, label: String? = nil, kind: ParamKind, defaultValue: ParamValue) {
        self.name = name
        self.label = label ?? name.capitalized
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

public enum NodeCategory: String, Codable, Sendable, CaseIterable {
    case input, math, vector, sdf, noise, color, utility, output
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

    public init(inputs: [String: String], outputs: [String: String], params: [String: String],
                enums: [String: String], types: [String: SocketType]) {
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.enums = enums; self.types = types
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

    public init(id: String, title: String, category: NodeCategory,
                inputs: [SocketDecl] = [], outputs: [SocketDecl] = [], params: [ParamDecl] = [],
                generics: [String: [SocketType]] = [:], requires: [String] = [], body: NodeBody) {
        self.id = id; self.title = title; self.category = category
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.generics = generics; self.requires = requires; self.body = body
    }

    public func input(named n: String) -> SocketDecl? { inputs.first { $0.name == n } }
    public func output(named n: String) -> SocketDecl? { outputs.first { $0.name == n } }
    public func param(named n: String) -> ParamDecl? { params.first { $0.name == n } }
}
