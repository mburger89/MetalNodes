import Foundation

/// The fullscreen-triangle vertex stage. Static: compiled once, never regenerated.
/// `uv` is 0…1 with the origin **bottom-left** (spec §9.1).
public enum VertexStage {
    public static let functionName = "mn_fullscreenVertex"

    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut mn_fullscreenVertex(uint vid [[vertex_id]]) {
        float2 pos = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
        VertexOut o;
        o.position = float4(pos, 0.0, 1.0);
        o.uv = pos * 0.5 + 0.5;
        return o;
    }
    """
}
