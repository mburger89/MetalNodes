import Foundation

/// A concrete value stored on a node instance: a socket's unconnected value,
/// a declared parameter, an enum case, or a texture asset reference.
public enum ParamValue: Codable, Sendable, Hashable {
    case float(Float)
    case float2(SIMD2<Float>)
    case float3(SIMD3<Float>)
    case float4(SIMD4<Float>)
    case int(Int32)
    case bool(Bool)
    case enumCase(String)
    case asset(AssetID?)

    /// The socket type this value can feed. `nil` for values that never become uniforms.
    public var socketType: SocketType? {
        switch self {
        case .float: .float
        case .float2: .float2
        case .float3: .float3
        case .float4: .float4
        case .int: .int
        case .bool: .bool
        case .enumCase, .asset: nil
        }
    }

    public var isUniformable: Bool { socketType != nil }

    /// MSL source literal, used only in tests and for `.constant` folding in exports.
    public var mslLiteral: String {
        func f(_ x: Float) -> String {
            x == x.rounded() && abs(x) < 1e7 ? String(format: "%.1f", x) : "\(x)"
        }
        switch self {
        case .float(let x): return f(x)
        case .float2(let v): return "float2(\(f(v.x)), \(f(v.y)))"
        case .float3(let v): return "float3(\(f(v.x)), \(f(v.y)), \(f(v.z)))"
        case .float4(let v): return "float4(\(f(v.x)), \(f(v.y)), \(f(v.z)), \(f(v.w)))"
        case .int(let i): return "\(i)"
        case .bool(let b): return b ? "true" : "false"
        case .enumCase(let c): return c
        case .asset: return "/* asset */"
        }
    }
}

/// What an input socket does when nothing is wired into it.
public enum SocketDefault: Sendable, Hashable, Codable {
    /// Codegen reports a diagnostic if the socket is unconnected.
    case required
    /// The value becomes a per-instance uniform slot, editable in the node body.
    case value(ParamValue)
    /// Falls back to the fragment's interpolated `uv`.
    case uv
}
