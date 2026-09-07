import Foundation

/// The last statement of a viewer program (spec §9.3, §19.3).
public enum ViewerWrap {
    /// The `float4` a viewed socket of `type` displays as (spec §9.3, §19.3). `float`/`int`
    /// normalise through the manual range; vectors widen; `bool` is on or off.
    ///
    /// One widening rule, two callers: the fragment program returns it, and the RealityKit preview
    /// makes it the emissive term so the viewed value lands flat on the mesh (spec §23.5).
    public static func expression(variable v: String, type: SocketType) -> String? {
        switch type {
        case .float: "float4(float3(saturate((\(v) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0)"
        case .int: "float4(float3(saturate((float(\(v)) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0)"
        case .float2: "float4(\(v), 0.0, 1.0)"
        case .float3: "float4(\(v), 1.0)"
        case .float4, .color: v
        case .bool: "float4(float3(\(v) ? 1.0 : 0.0), 1.0)"
        case .texture: nil
        }
    }

    /// The last statement of a viewer fragment program.
    public static func statement(variable v: String, type: SocketType) -> String? {
        expression(variable: v, type: type).map { "return \($0);" }
    }
}
