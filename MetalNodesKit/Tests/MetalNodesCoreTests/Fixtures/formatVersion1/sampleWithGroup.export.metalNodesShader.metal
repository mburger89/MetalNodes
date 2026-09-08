// MetalNodes fragment shader "metalNodesShader"
// Uniforms (buffer 0):
//   0  float4  p0  ← Color · Value
//   16  float2  resolution
//   24  float2  mouse
//   32  float  time
//   36  float  p1  ← Value Noise · Scale
//   40  float  p2  ← Float · Value
// Textures:

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 p0;
    float2 resolution;
    float2 mouse;
    float time;
    float p1;
    float p2;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

float mn_hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float mn_valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 s = f * f * (3.0 - 2.0 * f);
    float a = mn_hash21(i);
    float b = mn_hash21(i + float2(1.0, 0.0));
    float c = mn_hash21(i + float2(0.0, 1.0));
    float d = mn_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

struct G_bc672da2_Out {
    float out;
};

G_bc672da2_Out mn_g_Wobble_bc672da2(float2 uv, float time, float2 size, float2 mouse, float in_t, float u_a4758d47_value) {
    float v0;
    v0 = u_a4758d47_value;
    float v1;
    v1 = in_t;
    float v2;
    v2 = v1 * v0;
    float v3;
    v3 = sin(v2);
    G_bc672da2_Out out;
    out.out = v3;
    return out;
}

fragment float4 shaderMain(VertexOut in [[stage_in]],
                           constant Uniforms &u [[buffer(0)]]) {
    float2 v0;
    v0 = in.uv;
    float v1;
    v1 = mn_valueNoise(v0 * u.p1);
    float v2;
    v2 = u.time;
    G_bc672da2_Out r3 = mn_g_Wobble_bc672da2(in.uv, u.time, u.resolution, u.mouse, v2, u.p2);
    float v4;
    v4 = r3.out;
    float v5;
    float v6;
    float v7;
    v5 = float3(v0, 0.0).x;
    v6 = float3(v0, 0.0).y;
    v7 = float3(v0, 0.0).z;
    float3 v8;
    v8 = float3(v5, v6, v4);
    float4 v9;
    v9 = u.p0;
    float4 v10;
    v10 = mix(float4(v8, 1.0), v9, v1);
    return v10;
}
