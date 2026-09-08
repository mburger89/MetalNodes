#include <metal_stdlib>
using namespace metal;

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

struct G_96b04738_Out {
    float out;
};

G_96b04738_Out mn_g_Wobble_96b04738(float2 uv, float time, float2 size, float2 mouse, float in_t, float u_08fee0e1_value) {
    float v0;
    v0 = in_t;
    float v1;
    v1 = u_08fee0e1_value;
    float v2;
    v2 = v0 * v1;
    float v3;
    v3 = sin(v2);
    G_96b04738_Out out;
    out.out = v3;
    return out;
}

[[stitchable]] half4 stitchGroup(float2 position, half4 currentColor, float2 size, float time, float2 mouse, half4 p0, float p1, float p2) {
    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
    float2 v0;
    v0 = uv;
    float v1;
    v1 = mn_valueNoise(v0 * p1);
    float4 v2;
    v2 = float4(p0);
    float v3;
    v3 = time;
    G_96b04738_Out r4 = mn_g_Wobble_96b04738(uv, time, size, mouse, v3, p2);
    float v5;
    v5 = r4.out;
    float v6;
    float v7;
    float v8;
    v6 = float3(v0, 0.0).x;
    v7 = float3(v0, 0.0).y;
    v8 = float3(v0, 0.0).z;
    float3 v9;
    v9 = float3(v6, v7, v5);
    float4 v10;
    v10 = mix(float4(v9, 1.0), v2, v1);
    return half4(v10);
}
