// MetalNodes fragment shader "metalNodesShader"
// Uniforms (buffer 0):
//   0  float4  p0  ← Fragment Output · Color
//   16  float2  resolution
//   24  float2  mouse
//   32  float  time
// Textures:

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 p0;
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
    return u.p0;
}
