import Foundation

/// An implicit conversion inserted by codegen where a wire joins two sockets of
/// different types. `apply` wraps an MSL expression. See spec §7.2.
public struct Conversion: Sendable, Equatable {
    public let from: SocketType
    public let to: SocketType

    public var isIdentity: Bool {
        from == to || Set([from, to]) == Set([.color, .float4])
    }

    public func apply(_ expr: String) -> String {
        if isIdentity { return expr }
        // Route every scalar-ish source through `float`, then widen.
        if to.isVector {
            let asFloat: String
            switch from {
            case .int: asFloat = "float(\(expr))"
            case .bool: asFloat = "(\(expr) ? 1.0 : 0.0)"
            case .float: asFloat = expr
            default: return Conversion.vectorToVector(from: from, to: to, expr)
            }
            return Conversion.scalarToVector(to: to, asFloat)
        }
        // Destination is scalar (float / int / bool).
        let asFloat: String
        switch from {
        case .float: asFloat = expr
        case .int:
            if to == .float { return "float(\(expr))" }
            if to == .bool { return "(\(expr) != 0)" }
            asFloat = "float(\(expr))"
        case .bool:
            if to == .float { return "(\(expr) ? 1.0 : 0.0)" }
            if to == .int { return "int(\(expr))" }
            asFloat = expr
        case .float2: asFloat = "dot(\(expr), float2(0.5))"
        case .float3: asFloat = "dot(\(expr), float3(1.0 / 3.0))"
        case .float4: asFloat = "dot(\(expr), float4(0.25))"
        case .color:  asFloat = "dot((\(expr)).rgb, float3(0.2126, 0.7152, 0.0722))"
        case .texture: return expr // unreachable: convert(from:to:) refuses textures
        }
        switch to {
        case .float: return asFloat
        case .int: return "int(\(asFloat))"
        case .bool: return "(\(asFloat) != 0.0)"
        default: return asFloat // unreachable
        }
    }

    private static func scalarToVector(to: SocketType, _ f: String) -> String {
        switch to {
        case .float2: "float2(\(f))"
        case .float3: "float3(\(f))"
        case .float4: "float4(\(f))"
        case .color:  "float4(float3(\(f)), 1.0)"
        default: f
        }
    }

    private static func vectorToVector(from: SocketType, to: SocketType, _ e: String) -> String {
        let n = from.componentCount ?? 0
        let m = to.componentCount ?? 0
        if m < n {
            return m == 3 ? "(\(e)).xyz" : "(\(e)).xy"
        }
        switch (from, to) {
        case (.float2, .float3): return "float3(\(e), 0.0)"
        case (.float2, .float4), (.float2, .color): return "float4(\(e), 0.0, 1.0)"
        case (.float3, .float4), (.float3, .color): return "float4(\(e), 1.0)"
        default: return e
        }
    }
}

public enum ConversionRules {
    /// `nil` means the two types may not be connected.
    public static func convert(from: SocketType, to: SocketType) -> Conversion? {
        switch (from, to) {
        case (.texture, .texture): Conversion(from: from, to: to)
        case (.texture, _), (_, .texture): nil
        default: Conversion(from: from, to: to)
        }
    }
}
