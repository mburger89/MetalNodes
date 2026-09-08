// MetalNodes fragment shader "metalNodesShader"
// Uniforms (buffer 0):
//   0  float2  resolution
//   8  float2  mouse
//   16  float  time
// Textures:

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
    v0 = u.mouse;
    float v1;
    float v2;
    float v3;
    v1 = float3(v0, 0.0).x;
    v2 = float3(v0, 0.0).y;
    v3 = float3(v0, 0.0).z;
    float2 v4;
    v4 = u.resolution;
    float v5;
    float v6;
    float v7;
    v5 = float3(v4, 0.0).x;
    v6 = float3(v4, 0.0).y;
    v7 = float3(v4, 0.0).z;
    float2 v8;
    v8 = (in.uv - 0.5) * (u.resolution / u.resolution.y);
    float v9;
    float v10;
    float v11;
    v9 = float3(v8, 0.0).x;
    v10 = float3(v8, 0.0).y;
    v11 = float3(v8, 0.0).z;
    float3 v12;
    v12 = float3(v9, v1, v6);
    return float4(v12, 1.0);
}
