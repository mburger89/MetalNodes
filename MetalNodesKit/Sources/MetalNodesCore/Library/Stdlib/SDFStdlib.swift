extension MSLStdlib {
    static let sdf: [MSLFunction] = [
        MSLFunction(name: "sdBox", dependencies: [], source: """
        float mn_sdBox(float2 p, float2 b) {
            float2 d = abs(p) - b;
            return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        }
        """),
    ]
}
