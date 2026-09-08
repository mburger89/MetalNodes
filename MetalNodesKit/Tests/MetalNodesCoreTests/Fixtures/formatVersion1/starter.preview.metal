#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 mouse;
    float time;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

fragment float4 shaderMain(VertexOut in [[stage_in]],
                           constant Uniforms &u [[buffer(0)]]) {
    float2 v0;
    v0 = in.uv;
    return float4(v0, 0.0, 1.0);
}
