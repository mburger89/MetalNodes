import Foundation

/// The last statement of a viewer program (spec §9.3, §19.3).
public enum ViewerWrap {
    public static func statement(variable v: String, type: SocketType) -> String? {
        switch type {
        case .float: "return float4(float3(saturate((\(v) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);"
        case .int: "return float4(float3(saturate((float(\(v)) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);"
        case .float2: "return float4(\(v), 0.0, 1.0);"
        case .float3: "return float4(\(v), 1.0);"
        case .float4, .color: "return \(v);"
        case .bool: "return float4(float3(\(v) ? 1.0 : 0.0), 1.0);"
        case .texture: nil
        }
    }
}
