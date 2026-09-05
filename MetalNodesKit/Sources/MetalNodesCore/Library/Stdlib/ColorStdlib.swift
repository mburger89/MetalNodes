extension MSLStdlib {
    static let color: [MSLFunction] = [
        MSLFunction(name: "rampSegment", dependencies: [], source: """
        float4 mn_rampSegment(float t, float p0, float4 c0, float p1, float4 c1) {
            return mix(c0, c1, saturate((t - p0) / max(p1 - p0, 1e-5)));
        }
        """),
        MSLFunction(name: "ramp3", dependencies: ["rampSegment"], source: """
        float4 mn_ramp3(float t, float4 c0, float p1, float4 c1, float4 c2) {
            return t < p1 ? mn_rampSegment(t, 0.0, c0, p1, c1) : mn_rampSegment(t, p1, c1, 1.0, c2);
        }
        """),
        MSLFunction(name: "ramp4", dependencies: ["rampSegment"], source: """
        float4 mn_ramp4(float t, float4 c0, float p1, float4 c1, float p2, float4 c2, float4 c3) {
            if (t < p1) { return mn_rampSegment(t, 0.0, c0, p1, c1); }
            if (t < p2) { return mn_rampSegment(t, p1, c1, p2, c2); }
            return mn_rampSegment(t, p2, c2, 1.0, c3);
        }
        """),
        MSLFunction(name: "hsv2rgb", dependencies: [], source: """
        float3 mn_hsv2rgb(float3 c) {
            float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
        }
        """),
        MSLFunction(name: "rgb2hsv", dependencies: [], source: """
        float3 mn_rgb2hsv(float3 c) {
            float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
            float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }
        """),
    ]
}
