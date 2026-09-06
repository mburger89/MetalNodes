extension MSLStdlib {
    static let noise: [MSLFunction] = [
        MSLFunction(name: "hash22", dependencies: [], source: """
        float2 mn_hash22(float2 p) {
            float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.xx + p3.yz) * p3.zy);
        }
        """),
        MSLFunction(name: "perlin", dependencies: ["hash22"], source: """
        float mn_perlin(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            float2 g00 = mn_hash22(i) * 2.0 - 1.0;
            float2 g10 = mn_hash22(i + float2(1.0, 0.0)) * 2.0 - 1.0;
            float2 g01 = mn_hash22(i + float2(0.0, 1.0)) * 2.0 - 1.0;
            float2 g11 = mn_hash22(i + float2(1.0, 1.0)) * 2.0 - 1.0;
            float n = mix(mix(dot(g00, f), dot(g10, f - float2(1.0, 0.0)), u.x),
                          mix(dot(g01, f - float2(0.0, 1.0)), dot(g11, f - float2(1.0, 1.0)), u.x), u.y);
            return saturate(n * 0.7 + 0.5);
        }
        """),
        MSLFunction(name: "mod289_2", dependencies: [], source: """
        float2 mn_mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        """),
        MSLFunction(name: "mod289_3", dependencies: [], source: """
        float3 mn_mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        """),
        MSLFunction(name: "permute3", dependencies: ["mod289_3"], source: """
        float3 mn_permute3(float3 x) { return mn_mod289_3(((x * 34.0) + 1.0) * x); }
        """),
        MSLFunction(name: "simplex", dependencies: ["mod289_2", "mod289_3", "permute3"], source: """
        float mn_simplex(float2 v) {
            const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
            float2 i = floor(v + dot(v, C.yy));
            float2 x0 = v - i + dot(i, C.xx);
            float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
            float4 x12 = x0.xyxy + C.xxzz;
            x12.xy -= i1;
            i = mn_mod289_2(i);
            float3 p = mn_permute3(mn_permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
            float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
            m = m * m;
            m = m * m;
            float3 x = 2.0 * fract(p * C.www) - 1.0;
            float3 h = abs(x) - 0.5;
            float3 ox = floor(x + 0.5);
            float3 a0 = x - ox;
            m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
            float3 g;
            g.x = a0.x * x0.x + h.x * x0.y;
            g.yz = a0.yz * x12.xz + h.yz * x12.yw;
            return saturate(130.0 * dot(m, g) * 0.5 + 0.5);
        }
        """),
        MSLFunction(name: "voronoi", dependencies: ["hash22"], source: """
        float mn_voronoi(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float d = 8.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 g = float2(x, y);
                    float2 r = g + mn_hash22(i + g) - f;
                    d = min(d, dot(r, r));
                }
            }
            return sqrt(d);
        }
        """),
        MSLFunction(name: "fbm", dependencies: ["valueNoise"], source: """
        float mn_fbm(float2 p, int octaves) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < octaves; i++) {
                v += a * mn_valueNoise(p);
                p *= 2.0;
                a *= 0.5;
            }
            return v;
        }
        """),
    ]
}
