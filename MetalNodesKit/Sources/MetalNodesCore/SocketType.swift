import Foundation

/// The type carried by a socket. `color` is a `float4` with a semantic tag —
/// it draws differently and converts to `float` by luminance rather than average.
public enum SocketType: String, Codable, Sendable, CaseIterable, Hashable {
    case float, float2, float3, float4, color, int, bool, texture

    /// The MSL spelling of this type in expressions and local variables.
    public var mslName: String {
        switch self {
        case .float: "float"
        case .float2: "float2"
        case .float3: "float3"
        case .float4, .color: "float4"
        case .int: "int"
        case .bool: "bool"
        case .texture: "texture2d<float>"
        }
    }

    /// The MSL type used when this value lives in the `Uniforms` struct.
    /// `bool` is one byte in MSL, so it is stored as `int` and cast on read.
    public var uniformStorageName: String? {
        switch self {
        case .texture: nil
        case .bool: "int"
        default: mslName
        }
    }

    /// Size in bytes inside a `constant` buffer. **`float3` is 16, not 12.**
    public var byteSize: Int? {
        switch self {
        case .float, .int, .bool: 4
        case .float2: 8
        case .float3, .float4, .color: 16
        case .texture: nil
        }
    }

    /// Alignment in bytes inside a `constant` buffer — identical to size for every scalar and vector type.
    public var alignment: Int? { byteSize }

    public var componentCount: Int? {
        switch self {
        case .float, .int, .bool: 1
        case .float2: 2
        case .float3: 3
        case .float4, .color: 4
        case .texture: nil
        }
    }

    public var isUniformable: Bool { self != .texture }

    public var isVector: Bool {
        switch self {
        case .float2, .float3, .float4, .color: true
        default: false
        }
    }
}

/// A socket's declared type: concrete, or a generic parameter resolved per node instance.
public enum TypeRef: Hashable, Sendable, Codable {
    case concrete(SocketType)
    case generic(String)
}
