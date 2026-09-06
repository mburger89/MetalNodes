import Foundation

/// How generated statements spell a uniform read and the four system values (spec §19.2).
/// One emitter serves every target; only this differs.
public struct EmitEnvironment: Sendable {
    public var uniform: @Sendable (UniformField) -> String
    public var sys: [String: String]

    public static let sysNames: Set<String> = ["uv", "time", "resolution", "mouse"]

    public init(uniform: @escaping @Sendable (UniformField) -> String, sys: [String: String]) {
        self.uniform = uniform
        self.sys = sys
    }

    /// The fragment program (and every viewer program): a `constant Uniforms &u` buffer.
    public static let fragment = EmitEnvironment(
        uniform: { f in f.type == .bool ? "bool(u.\(f.name))" : "u.\(f.name)" },
        sys: ["uv": "in.uv", "time": "u.time", "resolution": "u.resolution", "mouse": "u.mouse"])

    /// Inside a stitchable function: uniforms are arguments named after their slots; SwiftUI has
    /// no int/bool `Shader.Argument`, so those arrive as `float` and are cast on read, and
    /// `.color(_:)` arrives as a premultiplied `half4` that is widened to `float4`.
    public static let stitchableFunction = EmitEnvironment(
        uniform: { f in
            switch f.type {
            case .bool: "bool(\(f.name))"
            case .int: "int(\(f.name))"
            case .color: "float4(\(f.name))"
            default: f.name
            }
        },
        sys: ["uv": "uv", "time": "time", "resolution": "size", "mouse": "mouse"])
}
