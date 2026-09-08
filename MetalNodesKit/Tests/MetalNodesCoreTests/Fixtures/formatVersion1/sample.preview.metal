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

fragment float4 shaderMain(VertexOut in [[stage_in]],
                           constant Uniforms &u [[buffer(0)]]) {
    float4 v0;
    v0 = u.p0;
    float2 v1;
    v1 = in.uv;
    float v2;
    v2 = mn_valueNoise(v1 * u.p1);
    float v3;
    float v4;
    float v5;
    v3 = float3(v1, 0.0).x;
    v4 = float3(v1, 0.0).y;
    v5 = float3(v1, 0.0).z;
    float v6;
    v6 = u.time;
    float v7;
    v7 = u.p2;
    float v8;
    v8 = v6 * v7;
    float v9;
    v9 = sin(v8);
    float3 v10;
    v10 = float3(v3, v4, v9);
    float4 v11;
    v11 = mix(float4(v10, 1.0), v0, v2);
    return v11;
}
