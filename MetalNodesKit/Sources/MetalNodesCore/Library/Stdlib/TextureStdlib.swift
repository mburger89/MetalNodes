extension MSLStdlib {
    /// Texture sampling and the two procedural sources (spec §21.2). `mn_sampler` is a program-scope
    /// declaration rather than a function, but it is pulled in and emitted exactly like one.
    static let texture: [MSLFunction] = [
        MSLFunction(name: "mn_sampler", dependencies: [], source: """
        constexpr sampler mn_sampler(filter::linear, address::repeat);
        """),
        MSLFunction(name: "mn_gradient", dependencies: [], source: """
        float mn_gradient(float2 uv, float angleDeg) {
            float a = angleDeg * (M_PI_F / 180.0);
            return saturate(dot(uv - 0.5, float2(cos(a), sin(a))) + 0.5);
        }
        """),
        MSLFunction(name: "mn_checker", dependencies: [], source: """
        float mn_checker(float2 uv, float scale) {
            return fmod(floor(uv.x * scale) + floor(uv.y * scale), 2.0);
        }
        """),
    ]
}
